# frozen_string_literal: true

module Phronomy
  module Memory
    module Pruner
      # Abstract base class for message pruners.
      #
      # Pruners receive the full message list and return a (potentially modified)
      # list. Common use cases include truncating oversized tool-call results,
      # redacting PII, or normalising content before token counting.
      class Base
        # Process the message list and return the (modified) result.
        #
        # @param messages [Array] message-like objects
        # @return [Array] pruned / modified messages
        def prune(messages)
          raise NotImplementedError, "#{self.class}#prune is not implemented"
        end
      end
    end
  end
end
