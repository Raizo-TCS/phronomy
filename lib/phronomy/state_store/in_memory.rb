# frozen_string_literal: true

module Phronomy
  module StateStore
    # In-memory state store. Stores state objects keyed by thread_id.
    # State objects are stored directly (no serialization), so this
    # backend is suitable for single-process use only.
    class InMemory < Base
      def initialize
        @store = {}
      end

      # @param state [Object] includes Phronomy::Graph::State; must have a non-nil thread_id
      # @return [self]
      def save(state)
        @store[state.thread_id] = state
        self
      end

      # @param thread_id [String]
      # @return [Object, nil] state object or nil
      def load(thread_id)
        @store[thread_id]
      end

      # @param thread_id [String]
      # @return [self]
      def clear(thread_id)
        @store.delete(thread_id)
        self
      end

      def clear_all
        @store.clear
        self
      end
    end
  end
end
