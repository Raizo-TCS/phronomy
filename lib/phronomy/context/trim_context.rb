# frozen_string_literal: true

require "set"

module Phronomy
  module Context
    # Context object passed to the +on_trim+ callback registered on an agent class.
    #
    # The callback receives a TrimContext and may call #remove to drop specific
    # messages from the conversation before the LLM is called. Changes affect
    # only the current invocation; the underlying memory store is not modified.
    #
    # Message elements are identified by a +:seq+ integer that is assigned
    # sequentially (0-based) when messages are loaded from memory each turn.
    #
    # @example Remove the oldest two messages when the budget is tight
    #   on_trim do |ctx|
    #     if ctx.total_tokens > ctx.budget.available(used: 0) * 0.9
    #       seqs_to_drop = ctx.message_elements.first(2).map { |e| e[:seq] }
    #       ctx.remove(seqs_to_drop)
    #     end
    #   end
    class TrimContext
      # @return [Phronomy::Context::TokenBudget, nil] token budget for this invocation
      attr_reader :budget

      # @return [Integer] total estimated token count of all current message elements
      attr_reader :total_tokens

      # @param message_elements [Array<Hash>]
      #   each element: { seq: Integer, message: Object, tokens: Integer, role: Symbol }
      # @param budget [Phronomy::Context::TokenBudget, nil]
      def initialize(message_elements:, budget:)
        @message_elements = message_elements.dup
        @budget = budget
        recalculate!
      end

      # Returns a snapshot of the current message elements (defensive copy).
      # Each element is a Hash with +:seq+, +:message+, +:tokens+, and +:role+.
      #
      # @return [Array<Hash>]
      def message_elements
        @message_elements.dup
      end

      # Remove messages identified by seq numbers.
      # Calling this multiple times accumulates removals.
      #
      # @param seqs [Integer, Array<Integer>] seq number(s) to remove
      # @return [self]
      def remove(seqs)
        seqs_set = Array(seqs).to_set
        @message_elements.reject! { |e| seqs_set.include?(e[:seq]) }
        recalculate!
        self
      end

      # Convenience: returns the plain message objects (without element metadata).
      #
      # @return [Array]
      def messages
        @message_elements.map { |e| e[:message] }
      end

      private

      def recalculate!
        @total_tokens = @message_elements.sum { |e| e[:tokens] }
      end
    end
  end
end
