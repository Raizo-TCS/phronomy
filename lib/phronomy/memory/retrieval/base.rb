# frozen_string_literal: true

module Phronomy
  module Memory
    module Retrieval
      # Abstract base class for conversation retrieval strategies.
      #
      # @abstract Subclass and implement #select.
      class Base
        # Select messages to inject into the context from a full chronological history.
        #
        # @param messages  [Array]        full history in chronological order
        # @param query     [String, nil]  current user input for query-aware retrieval
        # @param thread_id [String, nil]  active thread identifier for scoped retrieval
        # @return [Array] subset of messages in chronological order
        def select(messages, query: nil, thread_id: nil)
          raise NotImplementedError, "#{self.class}#select is not implemented"
        end
      end
    end
  end
end
