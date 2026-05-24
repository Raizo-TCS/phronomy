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
      # @api private
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
      # @api private
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
      # @api private
      def schedule(seconds:, &block)
        at(@now + seconds.to_f, &block)
      end

      # Returns the number of pending (un-fired) callbacks.
      # @return [Integer]
      # @api private
      def pending_callbacks
        @mutex.synchronize { @callbacks.size }
      end

      # Returns the logical time of the next pending callback, or +nil+ if
      # there are no pending callbacks.
      #
      # @return [Float, nil]
      # @api private
      def next_timer_at
        @mutex.synchronize { @callbacks.min_by { |(t, _)| t }&.first }
      end

      # Advance the clock exactly to the next pending callback and fire it.
      # Raises +RuntimeError+ when there are no pending callbacks.
      #
      # @return [self]
      # @api private
      def advance_to_next_timer
        target = next_timer_at
        raise "No pending timers to advance to" unless target

        advance(target - @now)
      end

      # Returns descriptive entries for all pending callbacks.
      # Used by {Phronomy::Runtime::FakeScheduler#pending_timers}.
      #
      # @return [Array<Hash>] each entry: +{ fire_at:, description: nil }+
      # @api private
      def pending_timer_entries
        @mutex.synchronize do
          @callbacks.sort_by { |(t, _)| t }.map { |(t, _)| {fire_at: t, description: nil} }
        end
      end

      private

      def fire_expired_callbacks!
        fired, @callbacks = @callbacks.partition { |(t, _)| t <= @now }
        fired.sort_by { |(t, _)| t }.each { |(_, cb)| cb.call }
      end
    end
  end
end
