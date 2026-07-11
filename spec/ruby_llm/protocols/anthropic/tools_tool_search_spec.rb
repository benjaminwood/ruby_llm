# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Protocols::Anthropic::Tools do
  def tool(name, deferred:, provider_options: {})
    base = instance_double(RubyLLM::Tool, name: name, description: "#{name} desc",
                                          parameters_schema: nil, declared_parameters: {},
                                          provider_options: provider_options)
    deferred ? RubyLLM::Tool::Registration.new(base, deferred: true) : base
  end

  describe '.function_for' do
    it 'omits defer_loading for a bare tool even if its class is deferred' do
      expect(described_class.function_for(tool('a', deferred: false))).not_to have_key(:defer_loading)
    end

    it 'emits defer_loading: true for a deferred Registration' do
      expect(described_class.function_for(tool('a', deferred: true))[:defer_loading]).to be(true)
    end

    it 'raises when a deferred tool also carries cache_control (Anthropic rejects it)' do
      deferred = tool('a', deferred: true, provider_options: { cache_control: { type: 'ephemeral' } })
      expect { described_class.function_for(deferred) }.to raise_error(ArgumentError, /cache_control/)
    end

    it 'allows cache_control on a non-deferred tool' do
      bare = tool('a', deferred: false, provider_options: { cache_control: { type: 'ephemeral' } })
      expect(described_class.function_for(bare)[:cache_control]).to eq({ type: 'ephemeral' })
    end
  end

  describe '.format_tools' do
    it 'does not append the native search primitive when nothing is deferred' do
      formatted = described_class.format_tools(a: tool('a', deferred: false), b: tool('b', deferred: false))
      expect(formatted.map { |t| t[:name] }).to contain_exactly('a', 'b')
      expect(formatted.map { |t| t[:type] }).not_to include('tool_search_tool_bm25_20251119')
    end

    it 'appends the native BM25 search primitive exactly once when any tool is deferred' do
      formatted = described_class.format_tools(a: tool('a', deferred: false), b: tool('b', deferred: true))
      expect(formatted.last).to eq(described_class::NATIVE_TOOL_SEARCH)
      expect(formatted.count { |t| t[:type] == 'tool_search_tool_bm25_20251119' }).to eq(1)
    end
  end

  describe '.find_tool_references' do
    it 'pulls tool names out of a tool_search_tool_result block' do
      blocks = [
        { 'type' => 'text', 'text' => 'searching' },
        { 'type' => 'server_tool_use', 'id' => 'srv_1', 'name' => 'tool_search_tool_bm25' },
        { 'type' => 'tool_search_tool_result', 'tool_use_id' => 'srv_1',
          'content' => { 'type' => 'tool_search_tool_search_result',
                         'tool_references' => [
                           { 'type' => 'tool_reference', 'tool_name' => 'weather_lookup' },
                           { 'type' => 'tool_reference', 'tool_name' => 'stock_price' }
                         ] } }
      ]
      expect(described_class.find_tool_references(blocks)).to eq(%w[weather_lookup stock_price])
    end

    it 'returns [] when there is no tool_search_tool_result block' do
      expect(described_class.find_tool_references([{ 'type' => 'text', 'text' => 'hi' }])).to eq([])
    end

    it 'tolerates an empty tool_references array' do
      blocks = [{ 'type' => 'tool_search_tool_result', 'content' => { 'tool_references' => [] } }]
      expect(described_class.find_tool_references(blocks)).to eq([])
    end
  end

  describe 'parse_completion_body surfaces tool search on the Message' do
    def parse(content_blocks)
      data = { 'model' => 'claude-haiku-4-5', 'content' => content_blocks,
               'usage' => { 'input_tokens' => 1, 'output_tokens' => 1 }, 'stop_reason' => 'tool_use' }
      RubyLLM::Protocols::Anthropic.allocate.send(:parse_completion_body, data, raw: nil)
    end

    let(:search_blocks) do
      [
        { 'type' => 'server_tool_use', 'id' => 'srv_1', 'name' => 'tool_search_tool_bm25',
          'input' => { 'query' => 'weather' } },
        { 'type' => 'tool_search_tool_result', 'tool_use_id' => 'srv_1',
          'content' => { 'type' => 'tool_search_tool_search_result',
                         'tool_references' => [{ 'type' => 'tool_reference', 'tool_name' => 'weather_lookup' }] } }
      ]
    end

    it 'exposes referenced tool names and the raw blocks for replay, in order' do
      message = parse([{ 'type' => 'text', 'text' => 'searching' }, *search_blocks])
      expect(message.tool_references).to eq(%w[weather_lookup])
      expect(message.tool_search_blocks).to eq(search_blocks)
    end

    it 'defaults both to empty' do
      message = parse([{ 'type' => 'text', 'text' => 'hi' }])
      expect(message.tool_references).to eq([])
      expect(message.tool_search_blocks).to eq([])
    end
  end

  describe 'history replay of tool-search blocks' do
    let(:protocol) { RubyLLM::Protocols::Anthropic.allocate }
    let(:srv) { { 'type' => 'server_tool_use', 'id' => 'srv_1', 'name' => 'tool_search_tool_bm25', 'input' => {} } }
    let(:result) do
      { 'type' => 'tool_search_tool_result', 'tool_use_id' => 'srv_1',
        'content' => { 'tool_references' => [{ 'tool_name' => 'weather_lookup' }] } }
    end

    def format(message)
      protocol.send(:format_message, message)
    end

    it 'replays the block pair verbatim before the tool_use blocks' do
      message = RubyLLM::Message.new(
        role: :assistant, content: 'searching', tool_search_blocks: [srv, result],
        tool_calls: { 't1' => RubyLLM::ToolCall.new(id: 't1', name: 'weather_lookup', arguments: { 'city' => 'B' }) }
      )

      types = format(message)[:content].map { |b| b['type'] || b[:type] }
      expect(types).to eq(%w[text server_tool_use tool_search_tool_result tool_use])
    end

    it 'replays blocks on assistant messages without tool calls too' do
      message = RubyLLM::Message.new(role: :assistant, content: 'found nothing',
                                     tool_search_blocks: [srv, result])
      types = format(message)[:content].map { |b| b['type'] || b[:type] }
      expect(types).to eq(%w[text server_tool_use tool_search_tool_result])
    end

    it 'drops an orphan result whose server_tool_use is missing (the API rejects the pairless form)' do
      message = RubyLLM::Message.new(role: :assistant, content: 'searching', tool_search_blocks: [result])
      types = format(message)[:content].map { |b| b['type'] || b[:type] }
      expect(types).to eq(['text'])
    end

    it 'drops an orphan server_tool_use whose result is missing (e.g. a truncated stream)' do
      message = RubyLLM::Message.new(role: :assistant, content: 'searching', tool_search_blocks: [srv])
      types = format(message)[:content].map { |b| b['type'] || b[:type] }
      expect(types).to eq(['text'])
    end

    it 'repairs pair order when a result somehow precedes its server_tool_use' do
      message = RubyLLM::Message.new(role: :assistant, content: 'searching', tool_search_blocks: [result, srv])
      types = format(message)[:content].map { |b| b['type'] || b[:type] }
      expect(types).to eq(%w[text server_tool_use tool_search_tool_result])
    end

    it 'places a cache boundary on the message content, not on a replayed search block' do
      message = RubyLLM::Message.new(role: :assistant, content: 'searching', tool_search_blocks: [srv, result])
      message.cache_until_here!
      blocks = format(message)[:content]

      cache_marked = blocks.select { |b| b[:cache_control] || b['cache_control'] }
      expect(cache_marked.map { |b| b[:type] || b['type'] }).to eq(['text'])
    end

    it 'adds nothing when a message carries no search blocks' do
      message = RubyLLM::Message.new(role: :assistant, content: 'plain')
      types = format(message)[:content].map { |b| b['type'] || b[:type] }
      expect(types).to eq(['text'])
    end

    it 'omits the blocks when the request no longer carries deferred tools (replay_search: false)' do
      message = RubyLLM::Message.new(role: :assistant, content: 'searching', tool_search_blocks: [srv, result])
      formatted = protocol.send(:format_message, message, replay_search: false)
      types = formatted[:content].map { |b| b['type'] || b[:type] }
      expect(types).to eq(['text'])
    end
  end

  describe 'streaming build_chunk surfaces tool_references' do
    let(:protocol) { RubyLLM::Protocols::Anthropic.allocate }

    it 'extracts references from a tool_search_tool_result content_block_start event' do
      data = {
        'type' => 'content_block_start', 'index' => 2,
        'content_block' => {
          'type' => 'tool_search_tool_result', 'tool_use_id' => 'srv_1',
          'content' => { 'type' => 'tool_search_tool_search_result',
                         'tool_references' => [{ 'type' => 'tool_reference', 'tool_name' => 'weather_lookup' }] }
        }
      }
      expect(protocol.send(:build_chunk, data).tool_references).to eq(%w[weather_lookup])
    end

    it 'yields no references for ordinary text deltas' do
      data = { 'type' => 'content_block_delta', 'delta' => { 'type' => 'text_delta', 'text' => 'hi' } }
      expect(protocol.send(:build_chunk, data).tool_references).to eq([])
    end
  end

  describe 'Providers::Anthropic::Capabilities.supports_tool_search?' do
    let(:caps) { RubyLLM::Providers::Anthropic::Capabilities }

    it 'is true for 4.5+ and 5.x models, including dated ids' do
      %w[claude-haiku-4-5 claude-opus-4-8 claude-sonnet-4-6 claude-fable-5
         claude-sonnet-5 claude-haiku-4-5-20251001].each do |id|
        expect(caps.supports_tool_search?(id)).to be(true)
      end
    end

    it 'is false for models that predate tool search and for malformed ids' do
      %w[claude-opus-4-1 claude-3-5-sonnet claude-opus-4 xclaude-opus-4-5].each do |id|
        expect(caps.supports_tool_search?(id)).to be(false)
      end
    end

    it 'does not read a date suffix on a major-only snapshot as a minor version' do
      expect(caps.supports_tool_search?('claude-opus-4-20250514')).to be(false)
      expect(caps.supports_tool_search?('claude-sonnet-4-20250514')).to be(false)
    end
  end

  describe 'providers reusing the protocol without a capabilities module' do
    it 'degrades instead of crashing (e.g. VertexAI Claude)' do
      provider = instance_double(RubyLLM::Provider, capabilities: nil, config: nil, connection: nil)
      model = instance_double(RubyLLM::Model, id: 'claude-sonnet-4-5')
      protocol = RubyLLM::Protocols::Anthropic.allocate
      allow(protocol).to receive_messages(provider: provider, model: model)

      expect(protocol.supports_deferred_tools?).to be(false)
    end
  end

  describe 'end-to-end request payload via Chat#render' do
    include_context 'with configured RubyLLM'

    let(:chat) do
      RubyLLM::Chat.new(model: 'claude-haiku-4-5', provider: :anthropic, assume_model_exists: true)
    end

    before do
      stub_const('WeatherLookupTool', Class.new(RubyLLM::Tool) do
        description 'Looks up the current weather for a city.'
        deferred
        parameter :city, description: 'City name'
        def execute(city:) = "weather in #{city}"
      end)
      stub_const('CurrentTimeTool', Class.new(RubyLLM::Tool) do
        description 'Returns the current time.'
        def execute = 'now'
      end)
    end

    it 'sends defer_loading: true on deferred tools and appends the BM25 primitive' do
      chat.with_tools(WeatherLookupTool)
      chat.with_tools(CurrentTimeTool)
      chat.ask_later('hi')

      tools = chat.render[:tools]
      weather = tools.find { |t| t[:name] == 'weather_lookup' }
      current = tools.find { |t| t[:name] == 'current_time' }

      expect(weather[:defer_loading]).to be(true)
      expect(current).not_to have_key(:defer_loading)
      expect(tools.count { |t| t[:type] == 'tool_search_tool_bm25_20251119' }).to eq(1)
    end
  end
end
