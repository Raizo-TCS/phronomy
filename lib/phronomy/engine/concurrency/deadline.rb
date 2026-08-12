# frozen_string_literal: true

module Phronomy
  module Concurrency
    # A point in time used as an upper bound for an operation.
    #
    # Uses the monotonic clock (+Process::CLOCK_MONOTONIC+) internally to avoid
    # skew from NTP adjustments or DST transitions.
    #
    # @example Create a 30-second deadline and check remaining time
    #   deadline = Phronomy::Concurrency::Deadline.in(30)
    #   sleep 1
    #   deadline.remaining_seconds   # => ~29.0
    #   deadline.expired?            # => false
    class Deadline
      # Creates a deadline that expires +seconds+ from now.
      #
      # @param seconds [Numeric] seconds from now until expiry
      # @return [Deadline]
      # @api private
      def self.in(seconds)
        new(Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds)
      end

      # @param monotonic_at [Float] absolute monotonic timestamp of expiry
      # @api private
      def initialize(monotonic_at)
        @monotonic_at = monotonic_at
      end

      # Returns +true+ when the deadline has passed.
      # @return [Boolean]
      # @api private
      def expired?
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @monotonic_at
      end

      # Seconds remaining until expiry.  Returns 0 when already expired.
      # @return [Float]
      # @api private
      def remaining_seconds
        remaining = @monotonic_at - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        [remaining, 0.0].max
      end

      # Attaches this deadline to a {CancellationToken} by cancelling the token
      # when the deadline expires. The Runtime timer queue is driven by EventLoop;
      # no timer-specific OS thread is created.
      #
      # @param token [CancellationToken]
      # @param timer_queue [Runtime::TimerQueue, nil] queue to register with;
      #   defaults to +Phronomy::Runtime.instance.timer_queue+
      # @return [self]
      # @api private
      def attach_to(token, timer_queue: Phronomy::Runtime.instance.timer_queue)
        seconds = remaining_seconds
        return self if seconds <= 0

        timer_queue.schedule(seconds: seconds) { token.cancel! }
        self
      end
    end
  end
end
