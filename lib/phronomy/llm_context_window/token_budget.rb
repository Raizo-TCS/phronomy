# frozen_string_literal: true

module Phronomy
  module LlmContextWindow
    # Immutable arithmetic value for one resolved model context budget.
    # Model-registry lookup belongs to Agent::TokenBudgetResolver.
    class TokenBudget
      attr_reader :context_window, :max_output_tokens

      # @api private
      def initialize(context_window:, max_output_tokens:)
        @context_window = Integer(context_window)
        @max_output_tokens = Integer(max_output_tokens)
      end

      # @api private
      def effective_input_limit
        [@context_window - @max_output_tokens, 0].max
      end

      # @api private
      def available(used: 0)
        [effective_input_limit - Integer(used), 0].max
      end
    end
  end
end
