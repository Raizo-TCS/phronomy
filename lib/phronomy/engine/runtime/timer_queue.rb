# frozen_string_literal: true

module Phronomy
  class Runtime
    # Threadless monotonic timer heap driven by EventLoop.
    class TimerQueue
      def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @clock = clock
        @heap = []
        @mutex = Mutex.new
        @stopped = false
        @wake = nil
      end

      # Installs a lightweight wake callback used when a newly scheduled timer
      # may change EventLoop's current wait deadline.
      def wake_with(&block)
        @mutex.synchronize { @wake = block }
        self
      end

      def schedule(seconds:, &callback)
        raise ArgumentError, "schedule requires a block" unless callback

        fire_at = @clock.call + seconds.to_f
        wake = nil
        @mutex.synchronize do
          raise Phronomy::PoolShutdownError, "TimerQueue has been shut down" if @stopped

          previous_first = @heap.first&.first
          @heap << [fire_at, callback]
          @heap.sort_by!(&:first)
          wake = @wake if previous_first.nil? || fire_at < previous_first
        end
        wake&.call
        self
      end

      # Seconds until the next timer is due, nil when no timers are pending.
      def seconds_until_next
        @mutex.synchronize do
          return nil if @stopped || @heap.empty?
          [@heap.first.first - @clock.call, 0.0].max
        end
      end

      # Executes all callbacks whose deadline is due. Must be called by EventLoop.
      def fire_due
        callbacks = @mutex.synchronize do
          return 0 if @stopped

          now = @clock.call
          due_count = @heap.bsearch_index { |(fire_at, _)| fire_at > now } || @heap.length
          @heap.shift(due_count).map(&:last)
        end

        callbacks.each do |callback|
          callback.call
        rescue => error
          Phronomy.configuration.logger&.error do
            "[TimerQueue] callback raised #{error.class}: #{error.message}"
          end
        end
        callbacks.length
      end

      def pending_count
        @mutex.synchronize { @heap.size }
      end

      def shutdown
        wake = @mutex.synchronize do
          return self if @stopped
          @stopped = true
          @heap.clear
          @wake
        end
        wake&.call
        self
      end
    end
  end
end
