# frozen_string_literal: true

module RubyLLM
  # A Message is a single entry in a chat conversation: a user prompt, an
  # assistant reply, a system instruction, or a tool result. Chat#ask
  # returns the model's reply as a Message, and Chat#messages holds the
  # transcript as an array of them.
  #
  #   response = chat.ask "What is the capital of France?"
  #   response.role          # => :assistant
  #   response.content       # => "The capital of France is Paris."
  #   response.finish_reason # => "stop"
  #
  # A Message also carries everything else the provider returned: token
  # usage (#tokens), reasoning output (#thinking), source citations
  # (#citations), and requested tool calls (#tool_calls).
  class Message
    # The valid message roles: +:system+, +:user+, +:assistant+, and +:tool+.
    ROLES = %i[system user assistant tool].freeze

    STOPPED_FINISH_REASONS = %w[stop end_turn stop_sequence].freeze
    MAX_TOKENS_FINISH_REASONS = %w[length max_tokens max_output_tokens model_context_window_exceeded].freeze
    TOOL_CALL_FINISH_REASONS = %w[tool_calls tool_use function_call].freeze
    CONTENT_FILTERED_FINISH_REASONS = %w[
      blocklist content_filter content_filtered guardrail_intervened image_recitation image_safety
      model_armor prohibited_content recitation safety spii
    ].freeze
    private_constant :STOPPED_FINISH_REASONS, :MAX_TOKENS_FINISH_REASONS, :TOOL_CALL_FINISH_REASONS,
                     :CONTENT_FILTERED_FINISH_REASONS

    # The role of the message: +:system+, +:user+, +:assistant+, or +:tool+.
    attr_reader :role

    # The message text as a String. Empty for assistant messages that only
    # request tool calls.
    attr_reader :content

    # The files sent or returned with the message, as an array of
    # Attachment objects.
    attr_reader :attachments

    # The ID of the model that produced the message, +nil+ on user messages.
    attr_reader :model

    # The tool calls the assistant requested, as a Hash of ToolCall objects
    # keyed by call ID, or +nil+.
    attr_reader :tool_calls

    # The ID of the tool call this message answers. Set only on tool result
    # messages.
    attr_reader :tool_call_id

    # The raw provider response: a Faraday::Response, or the result body
    # Hash for messages retrieved from a Batch.
    attr_reader :raw

    # The model's reasoning output as a Thinking object, or +nil+ when the
    # provider returned none.
    attr_reader :thinking

    # The token usage as a Tokens object, or +nil+ when the provider
    # reported none.
    attr_reader :tokens

    # The source citations as an array of Citation objects, normalized
    # across providers.
    attr_reader :citations

    # The names of deferred tools a provider's tool-search mechanism loaded
    # in response to this message, as an array of Strings. Empty unless the
    # chat uses deferred tools (see Chat#with_tools with +defer:+). Chat
    # records these on its ToolCatalog and reports them via
    # Chat#after_tool_search.
    attr_reader :tool_references

    # The provider-native tool-search blocks this assistant message carried
    # (e.g. Anthropic's +server_tool_use+/+tool_search_tool_result+ pairs),
    # as raw Hashes. Providers replay them verbatim when formatting the
    # conversation for the next request, per their tool-search contract.
    attr_reader :tool_search_blocks # :nodoc:

    # The provider-reported reason the model stopped, preserved as-is,
    # such as <tt>"stop"</tt>, <tt>"max_tokens"</tt>, or
    # <tt>"MAX_TOKENS"</tt>.
    attr_reader :finish_reason

    # The Chat this message belongs to, set when it is added to a
    # conversation. Backs #tool_results.
    attr_accessor :conversation # :nodoc:

    def initialize(options = {}) # :nodoc:
      @role = options.fetch(:role).to_sym
      @tool_calls = options[:tool_calls]
      @content = normalize_content(options.fetch(:content))
      @attachments = Attachment.wrap(options[:attachments])
      @model = options[:model]
      @tool_call_id = options[:tool_call_id]
      @tokens = options[:tokens] || Tokens.build(
        input: options[:input_tokens],
        output: options[:output_tokens],
        cache_read: options[:cache_read_tokens],
        cache_write: options[:cache_write_tokens],
        thinking: options[:thinking_tokens]
      )
      @raw = options[:raw]
      @thinking = options[:thinking]
      @citations = Array(options[:citations])
      @tool_references = Array(options[:tool_references])
      @tool_search_blocks = Array(options[:tool_search_blocks])
      @finish_reason = options[:finish_reason]
      @cache_until_here = options.fetch(:cache_until_here, false)

      ensure_valid_role
    end

    # Returns #content parsed as JSON, memoized after the first call.
    # Useful for reading structured output responses.
    #
    #   response = chat.with_schema(PersonSchema).ask "Generate a person"
    #   response.parsed # => {"name" => "Alice", "age" => 30}
    #
    def parsed
      @parsed ||= JSON.parse(content) if content
    end

    def with_attachments(attachments) # :nodoc:
      dup.tap { |message| message.instance_variable_set(:@attachments, Attachment.wrap(attachments)) }
    end

    # Returns +true+ if the assistant requested one or more tool calls,
    # +false+ otherwise.
    def tool_call?
      !tool_calls.nil? && !tool_calls.empty?
    end

    # Returns +true+ if the message carries the result of a tool call,
    # +false+ otherwise.
    def tool_result?
      !tool_call_id.nil? && !tool_call_id.empty?
    end

    # Returns the tool result messages answering this message's tool calls,
    # or an empty array when it made none. Mirrors the +tool_results+
    # association on acts_as_message records.
    def tool_results
      return [] unless tool_call? && conversation

      conversation.messages.select do |message|
        message.tool_result? && tool_calls.key?(message.tool_call_id)
      end
    end

    # Returns +true+ if #finish_reason indicates the model finished
    # normally, +false+ otherwise.
    def stopped?
      finish_reason_in?(STOPPED_FINISH_REASONS)
    end

    # Returns +true+ if the response was cut off by a token limit,
    # +false+ otherwise.
    def max_tokens?
      finish_reason_in?(MAX_TOKENS_FINISH_REASONS)
    end

    # Returns +true+ if the model stopped to request tool calls,
    # +false+ otherwise.
    def tool_call_stop?
      finish_reason_in?(TOOL_CALL_FINISH_REASONS)
    end

    # Returns +true+ if a provider safety filter stopped the response,
    # +false+ otherwise.
    def content_filtered?
      finish_reason_in?(CONTENT_FILTERED_FINISH_REASONS)
    end

    # Returns the standard input token count, same as <tt>tokens.input</tt>.
    def input_tokens
      tokens&.input
    end

    # Returns the billable output token count, same as
    # <tt>tokens.output</tt>.
    def output_tokens
      tokens&.output
    end

    # Returns the prompt cache read token count, same as
    # <tt>tokens.cache_read</tt>.
    def cache_read_tokens
      tokens&.cache_read
    end

    # Returns the prompt cache write token count, same as
    # <tt>tokens.cache_write</tt>.
    def cache_write_tokens
      tokens&.cache_write
    end

    # Returns the reasoning token count, same as <tt>tokens.thinking</tt>.
    def thinking_tokens
      tokens&.thinking
    end

    # Returns a Cost pricing this message's token usage in US dollars.
    # Pricing comes from #model_info, or from +model:+ when given.
    #
    #   response.cost.total
    #
    def cost(model: nil)
      Cost.new(tokens:, model: model || model_info)
    end

    # Marks this message as an explicit prompt cache boundary. Providers
    # that support prompt caching cache the conversation up to and
    # including this message. Returns +self+.
    #
    #   chat.add_message(role: :user, content: long_context).cache_until_here!
    #
    def cache_until_here!
      @cache_until_here = true
      self
    end

    # Returns +true+ if the message carries an explicit prompt cache
    # boundary, +false+ otherwise.
    def cache_until_here?
      @cache_until_here
    end

    # Returns a Hash of the message's attributes, with token counts merged
    # in as +:input_tokens+, +:output_tokens+, and related keys. Omits
    # +nil+ values and empty attachment and citation lists.
    def to_h
      {
        role: role,
        content: content,
        attachments: list_to_h(attachments),
        model: model,
        tool_calls: tool_calls,
        tool_call_id: tool_call_id,
        thinking: thinking&.text,
        thinking_signature: thinking&.signature,
        citations: list_to_h(citations),
        tool_references: (tool_references unless tool_references.empty?),
        tool_search_blocks: (tool_search_blocks unless tool_search_blocks.empty?),
        finish_reason: finish_reason,
        cache_until_here: cache_until_here? || nil
      }.merge(tokens ? tokens.to_h : {}).compact
    end

    def pretty_print_instance_variables # :nodoc:
      super - %i[@raw @conversation]
    end

    # Returns the Model record for #model from the model registry, or
    # +nil+ when the message has no model or the model is unknown.
    def model_info
      return unless model

      @model_info ||= RubyLLM.models.find(model)
    rescue ModelNotFoundError
      nil
    end

    private

    def list_to_h(list)
      list.empty? ? nil : list.map(&:to_h)
    end

    def finish_reason_in?(reasons)
      reasons.include?(finish_reason_key)
    end

    def finish_reason_key
      finish_reason.to_s.downcase.tr('-', '_')
    end

    def normalize_content(content)
      return '' if role == :assistant && content.nil? && tool_calls && !tool_calls.empty?
      return content if content.nil? || content.is_a?(String)

      raise ArgumentError,
            "Message content must be a String, got #{content.class}. " \
            'Pass files via attachments: and structured data as JSON.'
    end

    def ensure_valid_role
      raise InvalidRoleError, "Expected role to be one of: #{ROLES.join(', ')}" unless ROLES.include?(role)
    end
  end
end
