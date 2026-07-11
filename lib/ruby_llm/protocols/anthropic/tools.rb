# frozen_string_literal: true

module RubyLLM
  module Protocols
    class Anthropic
      # Tools methods of the Anthropic API integration
      module Tools
        module_function

        # Anthropic's native server-side BM25 tool-search primitive. Appended
        # to the tools array whenever any tool is deferred; Claude calls it
        # server-side to discover and load the deferred tools it needs.
        NATIVE_TOOL_SEARCH = {
          type: 'tool_search_tool_bm25_20251119',
          name: 'tool_search_tool_bm25'
        }.freeze

        def find_tool_uses(blocks)
          blocks.select { |c| c['type'] == 'tool_use' }
        end

        # Block types the server-side tool-search primitive adds to assistant
        # content. Kept raw on the Message and replayed verbatim on the next
        # request (see Chat#append_tool_search_blocks).
        TOOL_SEARCH_BLOCK_TYPES = %w[server_tool_use tool_search_tool_result].freeze

        # Extracts the names of tools discovered by the server-side tool-search
        # primitive from +tool_search_tool_result+ blocks, so Chat can record
        # them on its deferred catalog.
        def find_tool_references(blocks)
          blocks.select { |c| c['type'] == 'tool_search_tool_result' }.flat_map do |block|
            content = block['content']
            references = content.is_a?(Hash) ? Array(content['tool_references']) : []
            references.filter_map { |reference| reference['tool_name'] }
          end
        end

        # The raw tool-search blocks, in order, for verbatim history replay.
        def find_tool_search_blocks(blocks)
          blocks.select { |c| TOOL_SEARCH_BLOCK_TYPES.include?(c['type']) }
        end

        def format_tool_result(msg)
          {
            role: 'user',
            content: [format_tool_result_block(msg)]
          }
        end

        def format_tool_result_block(msg)
          {
            type: 'tool_result',
            tool_use_id: msg.tool_call_id,
            content: format_tool_result_content(msg)
          }
        end

        def format_tool_result_content(msg)
          search_results = RubyLLM::SearchResults.from_content(msg.content)
          return search_results.results.map { |result| search_result_block(result) } if search_results

          content = msg.content
          content = nil if content && content.empty?
          content = '(no output)' if content.nil? && msg.attachments.empty?

          Media.format_content(content, msg.attachments)
        end

        def search_result_block(result)
          {
            type: 'search_result',
            source: result[:url] || result[:title],
            title: result[:title],
            content: [{ type: 'text', text: result[:text] }],
            citations: { enabled: true }
          }
        end

        def function_for(tool)
          input_schema = tool.parameters_schema ||
                         RubyLLM::Tool::SchemaDefinition.from_parameters(tool.declared_parameters)&.json_schema

          declaration = {
            name: tool.name,
            description: tool.description,
            input_schema: input_schema || default_input_schema
          }
          declaration[:defer_loading] = true if deferred?(tool)
          unless tool.provider_options.empty?
            declaration = RubyLLM::Utils.deep_merge(declaration,
                                                    tool.provider_options)
          end

          reject_deferred_cache_control!(tool, declaration)
          declaration
        end

        # Anthropic rejects a tool that is both deferred and carries a
        # cache_control breakpoint (HTTP 400). Fail fast with a clear message
        # rather than letting the request 400 opaquely.
        def reject_deferred_cache_control!(tool, declaration)
          return unless declaration[:defer_loading]
          return unless declaration.key?(:cache_control) || declaration.key?('cache_control')

          raise ArgumentError,
                "Tool #{tool.name}: defer_loading cannot be combined with cache_control (Anthropic returns 400). " \
                'Put the cache breakpoint on a non-deferred tool.'
        end

        # Formats every tool for the request, appending the native tool-search
        # primitive when any tool is deferred so Claude can load the deferred
        # ones on demand.
        def format_tools(tools)
          formatted = tools.values.map { |tool| function_for(tool) }
          # dup: payload hashes must stay mutable for before_request hooks.
          formatted << NATIVE_TOOL_SEARCH.dup if formatted.any? { |entry| entry[:defer_loading] }
          formatted
        end

        # Only a Registration explicitly marked deferred emits the wire-level
        # flag; a bare Tool never does, regardless of its class default.
        def deferred?(tool)
          tool.is_a?(RubyLLM::Tool::Registration) && tool.deferred?
        end

        def extract_tool_calls(data)
          if json_delta?(data)
            extract_tool_call_delta(data)
          elsif content_block_start?(data)
            extract_tool_call_start(data)
          else
            parse_tool_calls(data['content_block'])
          end
        end

        def extract_tool_call_delta(data)
          { data['index'] => ToolCall.new(id: nil, name: nil, arguments: data.dig('delta', 'partial_json')) }
        end

        def extract_tool_call_start(data)
          tool_calls = parse_tool_calls(data['content_block'])
          return tool_calls if tool_calls.nil? || data['index'].nil?

          { data['index'] => tool_calls.values.first }
        end

        def content_block_start?(data)
          data['type'] == 'content_block_start'
        end

        def parse_tool_calls(content_blocks)
          return nil if content_blocks.nil?

          content_blocks = [content_blocks] unless content_blocks.is_a?(Array)

          tool_calls = {}
          content_blocks.each do |block|
            next unless block && block['type'] == 'tool_use'

            tool_calls[block['id']] = ToolCall.new(
              id: block['id'],
              name: block['name'],
              arguments: block['input']
            )
          end

          tool_calls.empty? ? nil : tool_calls
        end

        def default_input_schema
          {
            'type' => 'object',
            'properties' => {},
            'required' => [],
            'additionalProperties' => false,
            'strict' => true
          }
        end

        def build_tool_choice(tool_prefs)
          tool_choice = tool_prefs[:choice]
          calls_in_response = tool_prefs[:calls]
          tool_choice = :auto if tool_choice.nil?

          {
            type: case tool_choice
                  when :auto, :none
                    tool_choice
                  when :required
                    :any
                  else
                    :tool
                  end
          }.tap do |tc|
            tc[:name] = tool_choice if tc[:type] == :tool
            tc[:disable_parallel_tool_use] = calls_in_response == :one if tc[:type] != :none && !calls_in_response.nil?
          end
        end
      end
    end
  end
end
