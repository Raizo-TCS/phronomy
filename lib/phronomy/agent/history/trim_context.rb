# frozen_string_literal: true

module Phronomy
  module Agent
    module History
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
        # @return [Phronomy::LlmContextWindow::TokenBudget, nil] token budget for this invocation
        attr_reader :budget

        # @return [Integer] total estimated token count of all current message elements
        attr_reader :total_tokens

        # @param message_elements [Array<Hash>]
        #   each element: { seq: Integer, message: Object, tokens: Integer, role: Symbol }
        # @param budget [Phronomy::LlmContextWindow::TokenBudget, nil]
        # @api private
        def initialize(message_elements:, budget:)
          @message_elements = message_elements.dup
          @budget = budget
          recalculate!
        end

        # Returns a snapshot of the current message elements (defensive copy).
        # Each element is a Hash with +:seq+, +:message+, +:tokens+, and +:role+.
        #
        # @return [Array<Hash>]
        # @api private
        def message_elements
          @message_elements.dup
        end

        # Remove messages identified by seq numbers.
        # Calling this multiple times accumulates removals.
        #
        # @param seqs [Integer, Array<Integer>] seq number(s) to remove
        # @return [self]
        # @api private
        # mutant:disable - Array(seqs).to_set vs Array(seqs) and e[:seq] vs e.fetch(:seq) are genuine equivalent: Array#include? returns identical results for both
        def remove(seqs)
          seqs_set = Array(seqs).to_set
          @message_elements.reject! { |e| seqs_set.include?(e[:seq]) }
          recalculate!
          self
        end

        # Convenience: returns the plain message objects (without element metadata).
        #
        # @return [Array]
        # @api private
        # mutant:disable - e[:message] vs e.fetch(:message) is a genuine equivalent mutation: elements always carry :message
        def messages
          @message_elements.map { |e| e[:message] }
        end

        private

        # mutant:disable - e[:tokens] vs e.fetch(:tokens) is a genuine equivalent mutation: elements always carry :tokens
        def recalculate!
          @total_tokens = @message_elements.sum { |e| e[:tokens] }
        end
      end
    end
  end
end
