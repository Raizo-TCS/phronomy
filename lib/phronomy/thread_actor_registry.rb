# frozen_string_literal: true

module Phronomy
  # Global per-thread-id {Actor} registry.
  #
  # Maps the +:thread_id+ key from the +config:+ argument passed to
  # {Phronomy::Agent::Base#invoke} to a {Phronomy::Actor} instance.
  # Each thread_id gets exactly one Actor so that all operations for the same
  # conversation are serialised automatically.
  #
  # @example
  #   Phronomy::ThreadActorRegistry.for("user-42").call do
  #     # runs sequentially on the Actor's thread
  #   end
  module ThreadActorRegistry
    @actors = {}
    @registry_actor = Actor.new

    class << self
      # Returns (or lazily creates) the {Actor} for +thread_id+.
      #
      # When +Phronomy.configuration.max_actors+ is set, the registry evicts the
      # least-recently-used Actor (by stopping it) before inserting a new one.
      # Accessing an existing Actor moves it to the most-recently-used position.
      #
      # @param thread_id [String]
      # @return [Phronomy::Actor]
      def for(thread_id)
        @registry_actor.call do
          if @actors.key?(thread_id)
            # LRU touch: move to end (most-recently used)
            actor = @actors.delete(thread_id)
            @actors[thread_id] = actor
          else
            evict_lru_if_needed!
            @actors[thread_id] = Actor.new
          end
          @actors[thread_id]
        end
      end

      # Returns the current number of registered Actors.
      #
      # @return [Integer]
      def actor_count
        @registry_actor.call { @actors.size }
      end

      # Gracefully stops the Actor for +thread_id+ and removes it from the
      # registry.  The next call to {.for} with the same id creates a fresh Actor.
      #
      # @param thread_id [String]
      def stop(thread_id)
        @registry_actor.call { @actors.delete(thread_id) }&.stop
      end

      # Stops and removes every registered Actor.
      # Intended for test teardown and process shutdown.
      def clear_all
        actors = @registry_actor.call { @actors.values.tap { @actors.clear } }
        actors.each(&:stop)
      end

      # Yields each currently registered Actor.
      # A snapshot is taken so the registry cannot change while callers iterate.
      #
      # @yield [Phronomy::Actor]
      def each_actor(&block)
        @registry_actor.call { @actors.values.dup }.each(&block)
      end

      private

      # Evicts the least-recently-used Actor when the registry is at capacity.
      # Must be called from within @registry_actor.call { } to be thread-safe.
      def evict_lru_if_needed!
        max = Phronomy.configuration.max_actors
        return unless max && @actors.size >= max

        _lru_id, lru_actor = @actors.shift
        lru_actor.stop
      end
    end
  end
end
