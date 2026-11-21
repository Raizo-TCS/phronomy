# frozen_string_literal: true

module Phronomy
  class Runtime
    # Threadless monotonic timer heap driven by EventLoop.
    class TimerQueue
      def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @clock = clock
        @heap = []
        @mutex = Mutex.new
        @idle = ConditionVariable.new
        @firing = 0
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

      # Remove this registration without changing another user's timers. A
      # callback already taken by fire_due may still run; owners arbitrate once.
      # @api private
      def cancel(callback)
        @mutex.synchronize do
          before = @heap.length
          @heap.delete_if { |(_, registered)| registered == callback }
          @idle.broadcast if idle_locked?
          before != @heap.length
        end
      end

      # Wait without driving callbacks on the shutdown caller's thread. Both
      # registrations and callbacks already removed from the heap must finish.
      # @api private
      def wait_until_idle(deadline)
        @mutex.synchronize do
          until idle_locked?
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return false if remaining <= 0

            @idle.wait(@mutex, remaining)
          end
          true
        end
      end

      # Executes all callbacks whose deadline is due. Must be called by EventLoop.
      def fire_due
        callbacks = @mutex.synchronize do
          return 0 if @stopped

          now = @clock.call
          due_count = @heap.bsearch_index { |(fire_at, _)| fire_at > now } || @heap.length
          callbacks = @heap.shift(due_count).map(&:last)
          @firing += callbacks.length
          callbacks
        end

        callbacks.each do |callback|
          callback.call
        rescue => error
          begin
            Phronomy::RuntimeSettings.current.logger&.error do
              "[TimerQueue] callback raised #{error.class}: #{error.message}"
            end
          rescue
            # Reporting must not interrupt delivery to the remaining timers.
            nil
          end
        ensure
          @mutex.synchronize do
            @firing -= 1
            @idle.broadcast if idle_locked?
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
          @drained_on_shutdown = idle_locked?
          @stopped = true
          @heap.clear
          @idle.broadcast if idle_locked?
          @wake
        end
        wake&.call
        self
      end

      # Capture the first closure rather than a preceding idle observation:
      # a caller holding this queue may register after that observation.
      # @api private
      def drained_on_shutdown?
        @mutex.synchronize { @stopped && @drained_on_shutdown }
      end

      private

      def idle_locked?
        @heap.empty? && @firing.zero?
      end
    end
  end
end
