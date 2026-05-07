# frozen_string_literal: true

module Phronomy
  module Memory
    # Memory that retains only the most recent k turns (k*2 messages: user + assistant).
    #
    # When a token_budget is provided the window size is determined by tokens rather than
    # message count: messages are accumulated from newest to oldest until the budget's
    # effective_input_limit would be exceeded.
    class WindowMemory < Base
      def initialize(k: 10)
        @k = k
        @store = {}
      end

      # @param thread_id    [String]
      # @param token_budget [Phronomy::Context::TokenBudget, nil]
      # @return [Array]
      def load_messages(thread_id:, token_budget: nil, query: nil, **)
        messages = @store[thread_id] || []

        if token_budget
          fit_to_budget(messages, token_budget.effective_input_limit)
        else
          messages.last(@k * 2)
        end
      end

      def save_messages(thread_id:, messages:)
        @store[thread_id] = messages
      end

      def clear(thread_id:)
        @store.delete(thread_id)
      end

      private

      def fit_to_budget(messages, token_limit)
        accumulated = 0
        result = []
        messages.reverse_each do |msg|
          tokens = Phronomy::Context::TokenEstimator.estimate(msg.content.to_s)
          break if accumulated + tokens > token_limit

          accumulated += tokens
          result.unshift(msg)
        end
        result
      end
    end
  end
end
