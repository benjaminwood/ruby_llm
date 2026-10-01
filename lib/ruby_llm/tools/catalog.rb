# frozen_string_literal: true

module RubyLLM
  module Tools # :nodoc:
    # The names of a chat's deferred tools, and which of them the model
    # has loaded through tool search.
    class Catalog # :nodoc:
      def initialize
        @loaded_by_name = {}
      end

      def empty?
        @loaded_by_name.empty?
      end

      def names
        @loaded_by_name.keys
      end

      def deferred?(name)
        @loaded_by_name.key?(name.to_sym)
      end

      def loaded?(name)
        @loaded_by_name[name.to_sym] == true
      end

      def add(name)
        @loaded_by_name[name.to_sym] = false
        self
      end

      def remove(name)
        @loaded_by_name.delete(name.to_sym)
        self
      end

      def mark_loaded(name)
        sym = name.to_sym
        return nil unless @loaded_by_name[sym] == false

        @loaded_by_name[sym] = true
        sym
      end

      def inspect
        "#<#{self.class} deferred=#{@loaded_by_name.size} loaded=#{@loaded_by_name.count { |_, loaded| loaded }}>"
      end
    end
  end
end
