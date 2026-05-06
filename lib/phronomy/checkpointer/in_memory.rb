# frozen_string_literal: true

module Phronomy
  module Checkpointer
    # In-memory checkpointer. Stores state keyed by thread ID.
    class InMemory < Base
      def initialize
        @store = {}
      end

      # @param thread_id [String]
      # @param state [Object] graph state object
      # @param interrupted_at [Symbol, nil] node name where execution was interrupted
      # @param completed_node [Symbol, nil] last completed node name
      def save(thread_id, state, interrupted_at: nil, completed_node: nil)
        @store[thread_id] = Checkpoint.new(
          state: state,
          interrupted_at: interrupted_at,
          completed_node: completed_node
        )
        self
      end

      # @return [Checkpoint, nil]
      def load(thread_id)
        @store[thread_id]
      end

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
