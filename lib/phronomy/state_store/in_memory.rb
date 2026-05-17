# frozen_string_literal: true

module Phronomy
  module StateStore
    # In-memory state store. Data is held in an instance-level Hash keyed by
    # +thread_id+. Suitable for single-process use or testing only.
    class InMemory < Base
      def initialize
        @store = {}
      end

      # @param state [Object] includes Phronomy::WorkflowContext; must have a non-nil thread_id
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
