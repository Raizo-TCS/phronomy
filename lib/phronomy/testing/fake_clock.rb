# frozen_string_literal: true

module Phronomy
  module Testing
    # Deterministic manually-advanced clock for tests.
    class FakeClock
      attr_reader :now

      def initialize
        @now = 0.0
        @callbacks = []
        @mutex = Mutex.new
      end

      def advance(seconds)
        fired = @mutex.synchronize do
          @now += seconds.to_f
          due, @callbacks = @callbacks.partition { |(t, _)| t <= @now }
          due
        end
        # Match TimerQueue: callbacks may dispose or register timers themselves.
        fired.sort_by { |(t, _)| t }.each { |(_, callback)| callback.call }
        self
      end

      def at(at, &block)
        @mutex.synchronize { @callbacks << [at.to_f, block] }
        self
      end

      def schedule(seconds:, &block)
        at(@now + seconds.to_f, &block)
      end

      def cancel(callback)
        @mutex.synchronize do
          before = @callbacks.length
          @callbacks.delete_if { |(_, registered)| registered == callback }
          before != @callbacks.length
        end
      end

      def pending_callbacks
        @mutex.synchronize { @callbacks.size }
      end

      def next_timer_at
        @mutex.synchronize { @callbacks.min_by { |(t, _)| t }&.first }
      end

      def advance_to_next_timer
        target = next_timer_at
        raise "No pending timers to advance to" unless target
        advance(target - @now)
      end

      def pending_timer_entries
        @mutex.synchronize do
          @callbacks.sort_by { |(t, _)| t }.map do |(time, _)|
            {fire_at: time, description: nil}
          end
        end
      end
    end
  end
end
