# frozen_string_literal: true

module Phronomy
  class Runtime
    # Lazy-initialised timer service for a {Runtime} instance.
    #
    # Returns a {SchedulerTimerAdapter} when the backing scheduler is a
    # {DeterministicScheduler} (enabling virtual-time integration for the
    # `:fiber` backend), or a standard {TimerQueue} (OS-thread backed) for all
    # other schedulers.
    # @api private
    class TimerService
      # @param scheduler [Scheduler]
      # @api private
      def initialize(scheduler)
        @scheduler = scheduler
        @mutex = Mutex.new
        @timer = nil
      end

      # Returns (or lazily creates) the timer queue for this runtime.
      # @return [TimerQueue, SchedulerTimerAdapter]
      # @api private
      def timer_queue
        @mutex.synchronize do
          @timer ||= if @scheduler.is_a?(DeterministicScheduler)
            SchedulerTimerAdapter.new(@scheduler)
          else
            TimerQueue.new
          end
        end
      end

      # Shuts down the timer queue if it was started.
      # @return [void]
      # @api private
      def shutdown
        @mutex.synchronize { @timer&.shutdown }
      end
    end
  end
end
