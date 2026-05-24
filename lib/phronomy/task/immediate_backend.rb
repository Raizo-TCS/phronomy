# frozen_string_literal: true

module Phronomy
  class Task
    # Synchronous task backend that executes the block on the calling thread.
    #
    # Used by {Runtime::FakeScheduler} to allow tests to verify cooperative
    # scheduling behaviour without spawning additional Threads.  The block
    # runs to completion before {#initialize} returns, so {#await} and {#join}
    # always return immediately.
    #
    # Thread count invariant: +ImmediateBackend+ never creates a new Thread.
    class ImmediateBackend < Backend
      # Executes +block+ synchronously on the calling thread.
      # Saves and restores +Task.current+ so nested ImmediateBackend tasks
      # compose correctly.
      #
      # @param task  [Task]
      # @yieldreturn [Object]
      def initialize(task:, &block)
        super
        @value = nil
        @error = nil
        previous_task = Thread.current[:phronomy_current_task]
        Thread.current[:phronomy_current_task] = task
        task.transition!(:running)
        begin
          @value = block.call
          task.transition!(:completed)
        rescue CancellationError => e
          task.transition!(:cancelled)
          @error = e
        rescue => e
          task.transition!(:failed)
          @error = e
        ensure
          task.transition!(:cancelled) unless task.done?
          Thread.current[:phronomy_current_task] = previous_task
        end
      end

      # Returns the block's return value, or re-raises its exception.
      # @return [Object]
      # @raise [Exception]
      def await
        raise @error if @error

        @value
      end

      # Always +false+ — block has already completed by the time the task
      # is visible to callers.
      # @return [Boolean]
      def alive?
        false
      end

      # No-op: the block has already completed.
      # @return [self]
      def cancel!
        self
      end

      # Returns immediately — nothing to wait for.
      # @param limit [Numeric, nil] ignored
      # @return [self]
      def join(_limit = nil)
        self
      end
    end
  end
end
