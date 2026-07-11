# frozen_string_literal: true

module RubyLLM
  module Protocols
    # The OpenAI Responses API. Overrides the chat surface of Chat Completions;
    # embeddings, images, moderation, and transcription are inherited. Runs
    # stateless (store: false) and replays encrypted reasoning so multi-turn
    # tool calls work without server-side state.
    class Responses < ChatCompletions
      include Responses::Chat
      include Responses::Media
      include Responses::Streaming
      include Responses::Tools

      # The Responses API implements the tool-search seam via its native
      # tool_search tool and defer_loading flag, on the models its capabilities
      # mark as supporting it (gpt-5.4 and later). Chat Completions does not
      # implement the seam at all, so it inherits the +false+ default.
      # Providers that reuse this protocol without a capabilities module
      # conservatively degrade to eager registration.
      def supports_deferred_tools?
        capabilities = provider.capabilities
        !model.nil? && capabilities.respond_to?(:supports_tool_search?) &&
          capabilities.supports_tool_search?(model.id)
      end

      # Reasoning models reject the temperature parameter on this API.
      def maybe_normalize_temperature(temperature, model)
        return super unless reasoning_model?(model.id)

        unless temperature.nil?
          RubyLLM.logger.debug { "Model #{model.id} does not accept temperature on the Responses API, removing" }
        end
        nil
      end
    end
  end
end
