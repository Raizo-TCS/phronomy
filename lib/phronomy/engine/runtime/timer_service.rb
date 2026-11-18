# frozen_string_literal: true

module Phronomy
  class Runtime
    # Lazy owner of the Runtime's threadless timer queue.
    class TimerService
      def initialize
        @mutex = Mutex.new
        @timer = nil
        @waker = nil
      end

      def timer_queue
        @mutex.synchronize do
          @timer ||= TimerQueue.new.tap do |timer|
            timer.wake_with(&@waker) if @waker
          end
        end
      end

      def wake_with(&block)
        @mutex.synchronize do
          @waker = block
          @timer&.wake_with(&block)
        end
        self
      end

      def shutdown
        @mutex.synchronize do
          return true unless @timer

          @timer.shutdown
          @timer.drained_on_shutdown?
        end
      end

      # Capture the timer without holding the service lock during callbacks:
      # an admitted continuation may acquire this same service while draining.
      # @api private
      def wait_until_idle(deadline)
        timer = @mutex.synchronize { @timer }
        !timer || timer.wait_until_idle(deadline)
      end
    end
  end
end
