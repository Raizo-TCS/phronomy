# frozen_string_literal: true

module Phronomy
  module Memory
    module Retrieval
      # Retrieval strategy that returns the most recent k turns (k*2 messages).
      #
      # This is the simplest and most predictable strategy: older messages are
      # discarded without compression.
      #
      # @example
      #   retrieval = Phronomy::Memory::Retrieval::Recent.new(k: 10)
      #   manager = Phronomy::Memory::ConversationManager.new(
      #     storage: storage,
      #     retrieval: retrieval
      #   )
      class Recent < Base
        # @param k [Integer] number of turns to retain (each turn = 1 user + 1 assistant message)
        def initialize(k: 10)
          @k = k
        end

        # Returns the last k*2 messages from the history.
        #
        # @param messages [Array]       full chronological history
        # @param query    [String, nil] unused for recency-based retrieval
        # @return [Array]
        def select(messages, query: nil)
          messages.last(@k * 2)
        end
      end
    end
  end
end
