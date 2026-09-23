# frozen_string_literal: true

module Phronomy
  module LlmContextWindow
    # Immutable input-budget arithmetic. RubyLLM owns model capabilities.
    class TokenBudget
      attr_reader :max_input_tokens

      # @api private
      def initialize(max_input_tokens:)
        @max_input_tokens = Integer(max_input_tokens)
        raise ArgumentError, "max_input_tokens must be positive" unless @max_input_tokens.positive?
      end

      # @api private
      def effective_input_limit
        @max_input_tokens
      end

      # @api private
      def available(used: 0)
        [effective_input_limit - Integer(used), 0].max
      end
    end
  end
end
