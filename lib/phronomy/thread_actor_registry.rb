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
    @registry_mutex = Mutex.new

    class << self
      # Returns (or lazily creates) the {Actor} for +thread_id+.
      #
      # @param thread_id [String]
      # @return [Phronomy::Actor]
      def for(thread_id)
        @registry_mutex.synchronize { @actors[thread_id] ||= Actor.new }
      end

      # Gracefully stops the Actor for +thread_id+ and removes it from the
      # registry.  The next call to {.for} with the same id creates a fresh Actor.
      #
      # @param thread_id [String]
      def stop(thread_id)
        @registry_mutex.synchronize { @actors.delete(thread_id) }&.stop
      end

      # Stops and removes every registered Actor.
      # Intended for test teardown and process shutdown.
      def clear_all
        actors = @registry_mutex.synchronize { @actors.values.tap { @actors.clear } }
        actors.each(&:stop)
      end

      # Yields each currently registered Actor.
      # A snapshot is taken under the mutex so the registry cannot change
      # while callers iterate.
      #
      # @yield [Phronomy::Actor]
      def each_actor(&block)
        @registry_mutex.synchronize { @actors.values.dup }.each(&block)
      end
    end
  end
end
