# frozen_string_literal: true

module Phronomy
  module Concurrency
    # Cooperative cancellation token for Agent/Tool work.
    class CancellationToken
      # Creates a token that expires after +seconds+ measured with the monotonic clock.
      # @api public
      def self.timeout_after(seconds)
        monotonic_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        new(monotonic_deadline: monotonic_deadline)
      end

      # @param monotonic_deadline [Float, nil] internal monotonic timestamp.
      # @api public
      def initialize(monotonic_deadline: nil)
        @cancelled = false
        @monotonic_deadline = monotonic_deadline
        @mutex = Mutex.new
        @cancel_callbacks = []
      end

      # @api public
      def remaining_monotonic_seconds
        return nil if @monotonic_deadline.nil?

        remaining = @monotonic_deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        [remaining, 0.0].max
      end

      # @api public
      def on_cancel(&block)
        already_cancelled = @mutex.synchronize do
          if @cancelled
            true
          else
            @cancel_callbacks << block
            false
          end
        end
        block.call if already_cancelled
        self
      end

      # @api public
      def cancel!
        callbacks = @mutex.synchronize do
          return self if @cancelled

          @cancelled = true
          @cancel_callbacks.dup
        end
        callbacks.each(&:call)
        self
      end

      # @api public
      def cancelled?
        return true if @mutex.synchronize { @cancelled }

        !@monotonic_deadline.nil? &&
          Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @monotonic_deadline
      end

      # @api public
      def raise_if_cancelled!(message = "invocation cancelled")
        raise Phronomy::CancellationError, message if cancelled?
      end
    end
  end
end
