# frozen_string_literal: true

module Phronomy
  module StateStore
    # In-memory state store backed by per-thread-id {Phronomy::Actor} instances
    # from {Phronomy::ThreadActorRegistry}. Suitable for single-process use only.
    class InMemory < Base
      # Thread-local key for per-thread-id state data (namespaced by store
      # instance object_id to support multiple independent InMemory stores).
      THREAD_DATA_KEY = :phronomy_state_store_in_memory_data

      def initialize
      end

      # @param state [Object] includes Phronomy::Graph::State; must have a non-nil thread_id
      # @return [self]
      def save(state)
        store_id = object_id
        Phronomy::ThreadActorRegistry.for(state.thread_id).call do
          (Thread.current[THREAD_DATA_KEY] ||= {})[store_id] = state
        end
        self
      end

      # @param thread_id [String]
      # @return [Object, nil] state object or nil
      def load(thread_id)
        store_id = object_id
        Phronomy::ThreadActorRegistry.for(thread_id).call do
          (Thread.current[THREAD_DATA_KEY] ||= {})[store_id]
        end
      end

      # @param thread_id [String]
      # @return [self]
      def clear(thread_id)
        store_id = object_id
        Phronomy::ThreadActorRegistry.for(thread_id).call do
          (Thread.current[THREAD_DATA_KEY] ||= {}).delete(store_id)
        end
        self
      end

      def clear_all
        store_id = object_id
        Phronomy::ThreadActorRegistry.each_actor do |actor|
          actor.call { (Thread.current[THREAD_DATA_KEY] ||= {}).delete(store_id) }
        end
        self
      end
    end
  end
end
