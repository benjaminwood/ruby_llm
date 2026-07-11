# frozen_string_literal: true

module RubyLLM
  module Protocols
    # The Anthropic Messages API.
    class Anthropic < Protocol
      include Anthropic::Chat
      include Anthropic::Embeddings
      include Anthropic::Media
      include Anthropic::Models
      include Anthropic::Streaming
      include Anthropic::Tools

      # Anthropic implements the tool-search seam via its native server-side
      # tool_search_tool_bm25 primitive and defer_loading flag, on the models
      # its capabilities mark as supporting it (Opus 4.1 and earlier don't).
      # Providers that reuse this protocol without a capabilities module
      # (e.g. VertexAI) conservatively degrade to eager registration.
      def supports_deferred_tools?
        capabilities = provider.capabilities
        !model.nil? && capabilities.respond_to?(:supports_tool_search?) &&
          capabilities.supports_tool_search?(model.id)
      end
    end
  end
end
