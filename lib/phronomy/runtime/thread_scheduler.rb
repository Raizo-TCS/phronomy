# frozen_string_literal: true

module Phronomy
  class Runtime
    # Thread-based scheduler: spawns each task in a new OS thread.
    #
    # This is the default scheduler used by {Runtime} in production.
    # It delegates directly to {Task.spawn} with the default
    # {Task::ThreadBackend}, preserving the pre-282 behaviour exactly.
    class ThreadScheduler < Scheduler
      # Spawns +block+ as a new {Task} backed by a Thread.
      #
      # @param name   [String, nil]
      # @param parent [Task, nil]
      # @return [Task]
      def spawn(name:, parent:, &block)
        Task.spawn(name: name, parent: parent, &block)
      end

      # Yields the current thread's time slice to other runnable threads.
      # @return [void]
      def yield
        Thread.pass
      end
    end
  end
end
