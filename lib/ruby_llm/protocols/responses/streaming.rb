# frozen_string_literal: true

module RubyLLM
  module Protocols
    class Responses
      # Streaming methods of the OpenAI Responses API. Events are semantic:
      # each SSE data frame carries a `type` describing what changed.
      module Streaming
        module_function

        def build_chunk(data)
          case data['type']
          when 'response.output_text.delta'
            chunk content: data['delta']
          when 'response.reasoning_summary_text.delta'
            chunk thinking: Thinking.build(text: data['delta'])
          when 'response.output_text.annotation.added'
            chunk citations: parse_annotations([data['annotation']], nil)
          when 'response.output_item.added'
            build_item_added_chunk(data)
          when 'response.function_call_arguments.delta'
            chunk tool_calls: { data['output_index'] => ToolCall.new(id: nil, name: nil, arguments: data['delta']) }
          when 'response.output_item.done'
            build_item_done_chunk(data)
          when 'response.completed'
            build_completed_chunk(data)
          else
            chunk
          end
        end

        def build_item_added_chunk(data)
          item = data['item']
          return chunk unless item['type'] == 'function_call'

          chunk tool_calls: {
            data['output_index'] => ToolCall.new(id: item['call_id'], name: item['name'], arguments: +'',
                                                 namespace: item['namespace'])
          }
        end

        def build_item_done_chunk(data)
          item = data['item']
          if Chat::TOOL_SEARCH_ITEM_TYPES.include?(item['type'])
            return chunk(tool_references: tool_references_from_item(item), tool_search_blocks: [item])
          end
          return chunk unless item['type'] == 'reasoning' && item['encrypted_content']

          chunk thinking: Thinking.build(text: nil, signature: item['encrypted_content'])
        end

        # The hosted tool search reports loaded tools on a tool_search_output
        # item; surface their names as tool_references (and the raw item for
        # history replay) so the streamed Message matches the non-streaming
        # path (see Chat#parse_tool_references).
        def tool_references_from_item(item)
          Array(item['tools']).filter_map { |tool| tool['name'] }
        end

        def build_completed_chunk(data)
          response = data['response'] || {}

          chunk model: response['model'],
                finish_reason: response.dig('incomplete_details', 'reason'),
                **parse_usage(response['usage'] || {})
        end

        def chunk(content: nil, **attributes)
          Chunk.new(role: :assistant, content: content, **attributes)
        end
      end
    end
  end
end
