# frozen_string_literal: true

module Phronomy
  module StateStore
    # In-memory state store. Stores state objects keyed by thread_id.
    # State objects are stored directly (no serialization), so this
    # backend is suitable for single-process use only.
    class InMemory < Base
      def initialize
        @store = {}
        @mutex = Mutex.new
      end

      # @param state [Object] includes Phronomy::Graph::State; must have a non-nil thread_id
      # @return [self]
      def save(state)
        @mutex.synchronize { @store[state.thread_id] = state }
        self
      end

      # @param thread_id [String]
      # @return [Object, nil] state object or nil
      def load(thread_id)
        @mutex.synchronize { @store[thread_id] }
      end

      # @param thread_id [String]
      # @return [self]
      def clear(thread_id)
        @mutex.synchronize { @store.delete(thread_id) }
        self
      end

      def clear_all
        @mutex.synchronize { @store.clear }
        self
      end
    end
  end
end
