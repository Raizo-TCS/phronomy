# frozen_string_literal: true

module Phronomy
  # Immutable value object that holds token usage counts for a single LLM call
  # or an accumulated total across multiple calls.
  #
  # Fields mirror the values reported by RubyLLM::Tokens:
  #
  #   input          - tokens consumed by the input (prompt)
  #   output         - tokens produced by the model (completion)
  #   cached         - input tokens served from the provider's prompt cache
  #   cache_creation - input tokens written into the prompt cache (Anthropic)
  #
  # All fields are Integer or nil (nil means the provider did not report that
  # value for this call).
  #
  # @example Accumulate usage across a ReAct loop
  #   total = Phronomy::TokenUsage.zero
  #   chat.messages.each do |msg|
  #     total += Phronomy::TokenUsage.from_tokens(msg.tokens)
  #   end
  class TokenUsage
    attr_reader :input, :output, :cached, :cache_creation

    def initialize(input: nil, output: nil, cached: nil, cache_creation: nil)
      @input = input
      @output = output
      @cached = cached
      @cache_creation = cache_creation
    end

    # Returns a zero-valued TokenUsage suitable as an accumulator seed.
    def self.zero
      new(input: 0, output: 0, cached: 0, cache_creation: 0)
    end

    # Builds a TokenUsage from a RubyLLM::Tokens object. Returns zero
    # when tokens is nil (provider did not report usage).
    # nil fields within the tokens object are coerced to 0.
    def self.from_tokens(tokens)
      return zero if tokens.nil?

      new(
        input: tokens.input || 0,
        output: tokens.output || 0,
        cached: tokens.cached || 0,
        cache_creation: tokens.cache_creation || 0
      )
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
