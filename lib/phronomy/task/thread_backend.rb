# frozen_string_literal: true

module Phronomy
  class Task
    # Thread-based Task backend (default).
    #
    # Each task runs on its own OS thread.  Cancellation is delivered via
    # +Thread#raise(CancellationError)+, which cooperates with +rescue+ clauses
    # inside the block.  This backend is always available and requires no
    # external dependencies.
    #
    # When the cooperative scheduler backend is introduced, this backend will
    # remain available as the fallback for blocking I/O operations that must
    # run outside the scheduler (e.g. inside {BlockingAdapterPool}).
    class ThreadBackend < Backend
      def initialize(task:, &block)
        super
        @value = nil
        @error = nil
        @thread = Thread.new do
          Thread.current.name = task.name if task.name
          Thread.current[:phronomy_current_task] = task
          Thread.current[:phronomy_task_cpu_slice_start_ms] =
            Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
          task.transition!(:running)
          @value = block.call
          task.transition!(:completed)
        rescue CancellationError => e
          task.transition!(:cancelled)
          @error = e
        rescue => e
          task.transition!(:failed)
          @error = e
        ensure
          # Guard against Thread#raise firing before the rescue handler has a
          # chance to run (e.g. when cancel! is called immediately after spawn).
          task.transition!(:cancelled) unless task.done?
        end
      end

      # @return [Object]
      # @raise [Exception]
      def await
        @thread.join
        raise @error if @error

        @value
      end

      # @return [Boolean]
      def alive?
        @thread.alive?
      end

      # @return [self]
      def cancel!
        @thread.raise(CancellationError, "Task cancelled") if @thread.alive?
        self
      end

      # @param limit [Numeric, nil]
      # @return [Thread, nil]
      def join(limit = nil)
        @thread.join(limit)
      end
    end
  end
end
