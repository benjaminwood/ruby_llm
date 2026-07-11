# frozen_string_literal: true

# Grants the tool_search capability to a chat's current model so specs do
# not depend on the registry's capability data for that model.
module ToolSearchHelpers
  def grant_tool_search(chat)
    model = chat.model
    capabilities = model.capabilities | ['tool_search']
    chat.instance_variable_set(:@model, RubyLLM::Model.new(model.to_h.merge(capabilities: capabilities)))
    chat
  end
end

RSpec.configure do |config|
  config.include ToolSearchHelpers
end
