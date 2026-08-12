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
        @mutex.synchronize { @timer&.shutdown }
      end
    end
  end
end
