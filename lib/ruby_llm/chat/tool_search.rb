# frozen_string_literal: true

module RubyLLM
  class Chat
    # The provider-agnostic half of tool search: routing registrations into
    # the deferred catalog, assembling the tool set sent to the provider, and
    # recording which deferred tools the model discovered. How a deferred
    # tool and the search primitive are rendered, and how discoveries are
    # reported back, live in each protocol's tool-search adapter. Chat owns
    # the catalog; protocols own the vocabulary.
    #
    # Deferral is an intent recorded at registration and resolved at render
    # time: #effective_tools checks the current provider/model on every
    # request, so switching models (including fallbacks) activates or
    # degrades deferral without re-registering tools.
    module ToolSearch # :nodoc:
      def after_tool_search(&) # :nodoc:
        add_callback(:after_tool_search, &)
      end

      private

      def register_tool(tool, defer:)
        tool_instance = tool.is_a?(Class) ? tool.new : tool
        name = tool_instance.name.to_sym
        if defer_tool?(tool_instance, defer)
          @tools.delete(name)
          @tool_catalog.add(tool_instance)
        else
          @tool_catalog.remove(name)
          @tools[name] = tool_instance
        end
      end

      def defer_tool?(tool, explicit)
        return explicit ? true : false unless explicit.nil?

        tool.respond_to?(:deferred?) && tool.deferred?
      end

      # Deferred tools are wrapped in a deferred Registration when the current
      # provider/model supports tool search, discovered ones included, so the
      # tools array is identical across turns and the provider's prompt cache
      # survives. Otherwise they go out as ordinary tools.
      def effective_tools
        return tools if @tool_catalog.empty?

        if @provider.supports_deferred_tools?(@model, protocol: @protocol)
          deferred = @tool_catalog.deferred_tools.transform_values do |tool|
            Tool::Registration.new(tool, deferred: true)
          end
          deferred.merge(tools)
        else
          @tool_catalog.deferred_tools.merge(tools)
        end
      end

      # Active tools first, then the deferred catalog. Catalog lookup does not
      # depend on discovery: deferral is a context optimization, not an
      # authorization boundary, so a registered tool the model calls by name
      # always executes.
      def find_tool(name)
        sym = name.to_sym
        tools[sym] || @tool_catalog[sym]
      end

      def unavailable_tool_error(tool_call)
        {
          error: "Model tried to call unavailable tool `#{tool_call.name}`. " \
                 "Available tools: #{(tools.keys + @tool_catalog.deferred_tools.keys).to_json}."
        }
      end

      def record_tool_search(message)
        return if @tool_catalog.empty?

        names = Array(message.respond_to?(:tool_references) ? message.tool_references : nil).uniq
        return if names.empty?

        discovered = names.filter_map { |name| @tool_catalog.mark_loaded(name)&.name&.to_sym }
        run_callbacks(:after_tool_search, discovered) unless discovered.empty?
      end
    end
  end
end
