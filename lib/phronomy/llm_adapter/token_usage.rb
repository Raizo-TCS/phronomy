# frozen_string_literal: true

module Phronomy
  module LLMAdapter
    # Immutable usage counts. An omitted count remains nil; zero is a reported
    # measurement. SDK field translation belongs to the backend.
    # @api public
    class TokenUsage
      attr_reader :input, :output, :cached, :cache_creation

      def initialize(input: nil, output: nil, cached: nil, cache_creation: nil)
        [input, output, cached, cache_creation].each do |value|
          if !(value.nil? || (value.is_a?(Integer) && value >= 0))
            raise ArgumentError, "token usage must be non-negative Integers or nil"
          end
        end
        @input = input
        @output = output
        @cached = cached
        @cache_creation = cache_creation
        freeze
      end

      # Returns a zero-valued TokenUsage suitable as an accumulator seed.
      def self.zero
        new(input: 0, output: 0, cached: 0, cache_creation: 0)
      end

      # Adds two TokenUsage instances. nil fields are treated as 0 so that
      # partially-reported usage accumulates correctly.
      # When other is nil, returns self unchanged.
      def +(other)
        return self if other.nil?

        self.class.new(
          input: _add(input, other.input),
          output: _add(output, other.output),
          cached: _add(cached, other.cached),
          cache_creation: _add(cache_creation, other.cache_creation)
        )
      end

      def ==(other)
        other.is_a?(TokenUsage) &&
          input == other.input &&
          output == other.output &&
          cached == other.cached &&
          cache_creation == other.cache_creation
      end

      def to_h
        {input: input, output: output, cached: cached, cache_creation: cache_creation}
      end

      private

      def _add(a, b)
        return nil if a.nil? && b.nil?

        (a || 0) + (b || 0)
      end
    end
  end
end
