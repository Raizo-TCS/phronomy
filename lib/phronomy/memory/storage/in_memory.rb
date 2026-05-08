# frozen_string_literal: true

module Phronomy
  module Memory
    module Storage
      # In-process Hash-backed storage for conversation messages.
      # Messages are lost when the process exits.
      #
      # @example
      #   storage = Phronomy::Memory::Storage::InMemory.new
      #   manager = Phronomy::Memory::ConversationManager.new(storage: storage, ...)
      class InMemory < Base
        def initialize
          @store = {}
        end

        # @param thread_id [String]
        # @return [Array]
        def load(thread_id:)
          (@store[thread_id] || []).dup
        end

        # @param thread_id [String]
        # @param messages  [Array]
        def save(thread_id:, messages:)
          @store[thread_id] = messages.dup
        end

        # @param thread_id [String]
        def clear(thread_id:)
          @store.delete(thread_id)
        end
      end
    end
  end
end
