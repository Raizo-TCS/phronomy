# frozen_string_literal: true

module Phronomy
  class Runtime
    # A thread-safe timer queue backed by a single background thread.
    #
    # Replaces the pattern of spawning one +Thread.new { sleep(t); callback }+
    # per deadline.  Any number of timers share a single background thread that
    # sleeps until the earliest pending deadline.
    #
    # Use {#schedule} to register a one-shot callback; call {#shutdown} when the
    # queue is no longer needed (e.g. on process exit) to stop the background
    # thread cleanly.
    class TimerQueue
      # @param clock [#call] zero-argument callable that returns the current
      #   monotonic time in seconds (defaults to +Process::CLOCK_MONOTONIC+).
      #   Override in tests to inject a fake clock.
      # @api private
      def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @clock = clock
        @heap = [] # [[fire_at, callback], ...]
        @mutex = Mutex.new
        @cond = ConditionVariable.new
        @stopped = false
        @thread = Thread.new { run_loop }
        @thread.name = "phronomy-timer-queue"
      end

      # Schedule a one-shot callback to fire after +seconds+ from now.
      #
      # @param seconds [Numeric] delay before the callback fires
      # @yield called (in the timer thread) when the deadline is reached
      # @return [self]
      # @api private
      def schedule(seconds:, &callback)
        fire_at = @clock.call + seconds.to_f
        @mutex.synchronize do
          insert_sorted(fire_at, callback)
          @cond.signal
        end
        self
      end

      # Stop the background thread.  Pending (un-fired) callbacks are discarded.
      #
      # @return [self]
      # @api private
      def shutdown
        @mutex.synchronize do
          @stopped = true
          @cond.signal
        end
        @thread.join
        self
      end

      # Number of pending (not yet fired) callbacks.  Primarily for testing.
      # @return [Integer]
      # @api private
      def pending_count
        @mutex.synchronize { @heap.size }
      end

      private

      def insert_sorted(fire_at, callback)
        @heap << [fire_at, callback]
        @heap.sort_by! { |(t, _)| t }
      end

      def run_loop
        loop do
          callback = next_callback
          break if callback == :stopped
          callback&.call
        end
      end

      def next_callback
        @mutex.synchronize do
          loop do
            return :stopped if @stopped

            if @heap.empty?
              @cond.wait(@mutex)
            else
              now = @clock.call
              fire_at, = @heap.first
              if fire_at <= now
                return @heap.shift[1]
              else
                remaining = fire_at - now
                @cond.wait(@mutex, remaining)
              end
            end
          end
        end
      end
    end
  end
end
