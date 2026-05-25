# frozen_string_literal: true

module Phronomy
  class Runtime
    # Internal registry of active {Task} instances for a {Runtime}.
    #
    # Tracks every task that has been spawned but not yet completed so that
    # {Runtime#shutdown} can drain them.  Tasks that complete synchronously
    # (e.g. under {FakeScheduler} / {ImmediateBackend}) deregister themselves
    # before the caller returns from {Runtime#spawn}, so they are never added
    # to the registry in the first place.
    # @api private
    class TaskRegistry
      def initialize
        @mutex = Mutex.new
        @tasks = []
      end

      # Adds +task+ to the registry unless it already completed synchronously.
      # @param task [Task]
      # @return [void]
      # @api private
      def register(task)
        @mutex.synchronize { @tasks << task unless task.done? }
      end

      # Removes +task+ from the registry (called from the task's ensure block).
      # @param task [Task]
      # @return [void]
      # @api private
      def deregister(task)
        @mutex.synchronize { @tasks.delete(task) }
      end

      # Waits for all registered tasks to finish (used by {Runtime#shutdown}).
      # @return [void]
      # @api private
      def drain
        tasks = @mutex.synchronize { @tasks.dup }
        tasks.each do |t|
          t.join
        rescue
          nil
        end
      end
    end
  end
end
