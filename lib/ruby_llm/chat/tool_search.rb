# frozen_string_literal: true

module RubyLLM
  class Chat
    # Deferred tool registration and the tool set rendered for the request.
    module ToolSearch # :nodoc:
      def after_tool_search(&) # :nodoc:
        add_callback(:after_tool_search, &)
      end

      private

      def register_tool(tool, defer:)
        tool_instance = tool.is_a?(Class) ? tool.new : tool
        name = tool_instance.name.to_sym
        @tools[name] = tool_instance
        defer_tool?(tool_instance, defer) ? @tool_catalog.add(name) : @tool_catalog.remove(name)
      end

      def defer_tool?(tool, explicit)
        return explicit ? true : false unless explicit.nil?

        tool.respond_to?(:deferred?) && tool.deferred?
      end

      # Loaded tools stay deferred on the wire so the tools array is the same
      # on every turn and the provider's prompt cache survives.
      def effective_tools
        return tools if @tool_catalog.empty? || !@provider.supports_deferred_tools?(@model, protocol: @protocol)

        tools.to_h do |name, tool|
          [name, @tool_catalog.deferred?(name) ? Tool::Registration.new(tool, deferred: true) : tool]
        end
      end

      def record_tool_search(message)
        return if @tool_catalog.empty?

        loaded = message.tool_references.filter_map { |name| @tool_catalog.mark_loaded(name) }
        run_callbacks(:after_tool_search, loaded) unless loaded.empty?
      end
    end
  end
end
