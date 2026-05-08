# frozen_string_literal: true

module Phronomy
  module Memory
    # Memory that retains only the most recent k turns (k*2 messages: user + assistant).
    #
    # When a token_budget is provided the window size is determined by tokens rather than
    # message count: messages are accumulated from newest to oldest until the budget's
    # effective_input_limit would be exceeded.
    class WindowMemory < Base
      # @param k     [Integer]        number of turns to retain (each turn = user + assistant message)
      # @param async [Boolean]        see {Phronomy::Memory::Base#initialize}
      # @param queue [Symbol, String] see {Phronomy::Memory::Base#initialize}
      def initialize(k: 10, async: false, queue: :default)
        super(async: async, queue: queue)
        @k = k
        @store = {}
      end

      # @param thread_id [String]
      # @return [Array]
      def load_messages(thread_id:, query: nil, **)
        messages = @store[thread_id] || []
        messages.last(@k * 2)
      end

      # @param thread_id [String]
      # @param messages  [Array]
      def save_messages(thread_id:, messages:)
        @store[thread_id] = messages
      end

      # @param thread_id [String]
      def clear(thread_id:)
        @store.delete(thread_id)
      end
    end
  end
end
