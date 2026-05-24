# frozen_string_literal: true

module Phronomy
  module Testing
    # A deterministic, manually-advanced clock for use in tests.
    #
    # Replaces real +Process.clock_gettime+ calls so that time-sensitive code
    # can be tested without relying on wall-clock sleeps.
    #
    # @example
    #   clock = Phronomy::Testing::FakeClock.new
    #   clock.now        # => 0.0
    #   clock.advance(5) # advance by 5 seconds
    #   clock.now        # => 5.0
    class FakeClock
      # @return [Float] the current logical time in seconds since the epoch (t=0)
      attr_reader :now

      def initialize
        @now = 0.0
        @callbacks = [] # [[fire_at, block], ...]
        @mutex = Mutex.new
      end

      # Advance the clock by +seconds+ and fire any registered callbacks whose
      # deadline has passed.
      #
      # @param seconds [Numeric]
      # @return [self]
      def advance(seconds)
        @mutex.synchronize do
          @now += seconds.to_f
          fire_expired_callbacks!
        end
        self
      end

      # Register a one-shot callback that fires when the clock reaches +at+.
      #
      # @param at [Numeric] logical time to fire
      # @yield called with no arguments when the clock reaches +at+
      # @return [self]
      def at(at, &block)
        @mutex.synchronize { @callbacks << [at.to_f, block] }
        self
      end

      # Schedule a one-shot callback to fire after +seconds+ from the current
      # logical time.  This is the same interface as {Runtime::TimerQueue#schedule}
      # so that a +FakeClock+ can be passed as a +timer_queue:+ argument in tests.
      #
      # @param seconds [Numeric] delay in logical seconds
      # @yield called when the clock reaches the scheduled time
      # @return [self]
      def schedule(seconds:, &block)
        at(@now + seconds.to_f, &block)
      end

      # Returns the number of pending (un-fired) callbacks.
      # @return [Integer]
      def pending_callbacks
        @mutex.synchronize { @callbacks.size }
      end

      private

      def fire_expired_callbacks!
        fired, @callbacks = @callbacks.partition { |(t, _)| t <= @now }
        fired.sort_by { |(t, _)| t }.each { |(_, cb)| cb.call }
      end
    end
  end
end
