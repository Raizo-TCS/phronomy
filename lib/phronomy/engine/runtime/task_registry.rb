# frozen_string_literal: true

module Phronomy
  class Runtime
    # Internal registry of active {Task} instances for a {Runtime}.
    #
    # Tracks every task that has been spawned but not yet completed so that
    # {Runtime#shutdown} can drain them. Tasks that complete synchronously
    # deregister themselves before the caller returns from {Runtime#spawn}.
    # @api private
    class TaskRegistry
      def initialize
        @mutex = Mutex.new
        @tasks = []
      end

      # Adds +task+ unless it already completed synchronously.
      # @api private
      def register(task)
        @mutex.synchronize { @tasks << task unless task.done? }
      end

      # Removes +task+ from the registry.
      # @api private
      def deregister(task)
        @mutex.synchronize { @tasks.delete(task) }
      end

      # Waits for registered tasks until the absolute monotonic +deadline+.
      # The registry is re-snapshotted because tasks may create follow-up tasks
      # while Runtime shutdown is draining accepted work.
      #
      # @param deadline [Numeric] absolute Process::CLOCK_MONOTONIC value
      # @return [Symbol] +:empty+ or +:timeout+
      # @api private
      def drain_until(deadline)
        loop do
          tasks = snapshot
          return :empty if tasks.empty?

          tasks.each do |task|
            remaining = deadline - monotonic_now
            return :timeout if remaining <= 0

            begin
              task.join(remaining)
            rescue
              # Some backends re-raise the task error from join. The task's
              # ensure block still deregisters it, so continue the drain.
              nil
            end

            return :timeout if task.alive? && monotonic_now >= deadline
          end

          return :empty if empty?
          return :timeout if monotonic_now >= deadline
        end
      end

      # Compatibility helper for callers that explicitly require an unbounded
      # drain. Runtime#shutdown uses {#drain_until}.
      # @api private
      def drain
        snapshot.each do |task|
          task.join
        rescue
          nil
        end
      end

      # @return [Boolean]
      # @api private
      def empty?
        @mutex.synchronize { @tasks.empty? }
      end

      # @return [Integer]
      # @api private
      def size
        @mutex.synchronize { @tasks.size }
      end

      private

      def snapshot
        @mutex.synchronize { @tasks.dup }
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
