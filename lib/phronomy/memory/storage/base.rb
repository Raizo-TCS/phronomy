# frozen_string_literal: true

module Phronomy
  module Memory
    module Storage
      # Abstract base class for conversation storage backends.
      #
      # @abstract Subclass and implement #load, #save, and #clear.
      class Base
        # Load all messages for a thread in chronological order.
        #
        # @param thread_id [String]
        # @return [Array]
        def load(thread_id:)
          raise NotImplementedError, "#{self.class}#load is not implemented"
        end

        # Persist messages for a thread (replaces existing messages).
        #
        # @param thread_id [String]
        # @param messages  [Array]
        def save(thread_id:, messages:)
          raise NotImplementedError, "#{self.class}#save is not implemented"
        end

        # Delete all messages for a thread.
        #
        # @param thread_id [String]
        def clear(thread_id:)
          raise NotImplementedError, "#{self.class}#clear is not implemented"
        end
      end
    end
  end
end
