# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Tools::Catalog do
  describe '#add and #remove' do
    it 'starts empty and tracks names as Symbols' do
      catalog = described_class.new
      expect(catalog).to be_empty

      expect(catalog.add('foo')).to be(catalog)
      expect(catalog.names).to eq([:foo])
      expect(catalog).to be_deferred(:foo)
      expect(catalog).to be_deferred('foo')
      expect(catalog).not_to be_deferred(:bar)
    end

    it 'forgets a name and its loaded state' do
      catalog = described_class.new.add(:foo).add(:bar)
      catalog.mark_loaded(:foo)

      expect(catalog.remove(:foo)).to be(catalog)
      expect(catalog.names).to eq([:bar])
      expect(catalog).not_to be_loaded(:foo)
      expect(catalog.remove(:missing)).to be(catalog)
    end

    it 'starts a fresh lifecycle when a loaded name is added again' do
      catalog = described_class.new.add(:foo)
      catalog.mark_loaded(:foo)

      catalog.add(:foo)

      expect(catalog).not_to be_loaded(:foo)
      expect(catalog.mark_loaded(:foo)).to eq(:foo)
    end
  end

  describe '#mark_loaded' do
    it 'records the first load of a deferred name and returns it' do
      catalog = described_class.new.add(:foo)

      expect(catalog.mark_loaded('foo')).to eq(:foo)
      expect(catalog).to be_loaded(:foo)
      expect(catalog.mark_loaded(:foo)).to be_nil
    end

    it 'ignores names that are not deferred' do
      catalog = described_class.new.add(:foo)

      expect(catalog.mark_loaded(:missing)).to be_nil
      expect(catalog).not_to be_loaded(:missing)
    end
  end

  describe '#inspect' do
    it 'reports counts' do
      catalog = described_class.new.add(:foo).add(:bar)
      catalog.mark_loaded(:foo)
      expect(catalog.inspect).to eq('#<RubyLLM::Tools::Catalog deferred=2 loaded=1>')
    end
  end
end
