# frozen_string_literal: true

module Phronomy
  module Concurrency
    # A counting semaphore that enforces a concurrency cap across a named
    # resource category (e.g. agent tasks, tool tasks, LLM calls).
    #
    # When +max_concurrent+ is +nil+ the gate is a no-op and all callers
    # pass through immediately without acquiring a slot.
    #
    # Backpressure behaviour when the gate is full is controlled by the
    # +on_full:+ keyword:
    #   +:reject+  — raise {Phronomy::BackpressureError} immediately
    #   +:wait+    — block the calling fiber/thread until a slot is free
    #   +:timeout+ — like +:wait+ but raises {Phronomy::BackpressureError}
    #               after +timeout:+ seconds if no slot becomes available
    #
    # @example
    #   gate = Phronomy::Concurrency::ConcurrencyGate.new(max_concurrent: 5, name: :agent)
    #   gate.acquire(on_full: :reject) do
    #     run_agent_task
    #   end
    class ConcurrencyGate
      # @param max_concurrent [Integer, nil] concurrency cap; nil = unlimited
      # @param name [Symbol, String, nil] human-readable label used in error messages
      # @api private
      def initialize(max_concurrent:, name: nil)
        @max = max_concurrent
        @name = name
        @mutex = Mutex.new
        @cond = ConditionVariable.new
        @count = 0
      end

      # Returns the configured cap (or nil when unlimited).
      attr_reader :max

      # Returns the name label.
      attr_reader :name

      # Returns the number of slots currently in use.
      def current_count
        @mutex.synchronize { @count }
      end

      # Acquires a slot, executes +block+, then releases the slot.
      # When the gate is unlimited (max is nil) the block runs directly.
      #
      # @param on_full [:reject, :wait, :timeout] backpressure strategy
      # @param timeout [Numeric, nil] seconds before +:timeout+ gives up
      # @yield
      # @return block return value
      # @raise [Phronomy::BackpressureError] when +:reject+ or +:timeout+ fires
      # @api private
      def acquire(on_full: :wait, timeout: nil, &block)
        return block.call if @max.nil?

        _acquire_slot(on_full: on_full, timeout: timeout)
        begin
          block.call
        ensure
          _release_slot
        end
      end

      private

      def _acquire_slot(on_full:, timeout:)
        scheduler = Phronomy::Runtime::Scheduler.current
        if scheduler
          _acquire_slot_coop(scheduler, on_full: on_full, timeout: timeout)
        else
          _acquire_slot_threaded(on_full: on_full, timeout: timeout)
        end
      end

      def _acquire_slot_coop(scheduler, on_full:, timeout:)
        # In cooperative mode all tasks run on the same thread, so no mutex needed.
        deadline = timeout ? (scheduler.virtual_time + timeout) : nil
        @coop_signal ||= scheduler.new_signal

        loop do
          if @count < @max
            @count += 1
            return
          end

          case on_full
          when :reject
            raise Phronomy::BackpressureError,
              "ConcurrencyGate[#{@name}] at capacity (#{@max}); " \
              "increase max_concurrent_#{@name}_tasks or retry later"
          when :timeout
            if deadline && scheduler.virtual_time >= deadline
              raise Phronomy::BackpressureError,
                "ConcurrencyGate[#{@name}] timed out waiting for a free slot (cap: #{@max})"
            end
            scheduler.wait_for_signal(@coop_signal)
            if deadline && scheduler.virtual_time >= deadline
              raise Phronomy::BackpressureError,
                "ConcurrencyGate[#{@name}] timed out waiting for a free slot (cap: #{@max})"
            end
          else # :wait
            scheduler.wait_for_signal(@coop_signal)
          end
        end
      end

      def _acquire_slot_threaded(on_full:, timeout:)
        deadline = timeout ? (Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout) : nil

        @mutex.synchronize do
          loop do
            if @count < @max
              @count += 1
              return
            end

            case on_full
            when :reject
              raise Phronomy::BackpressureError,
                "ConcurrencyGate[#{@name}] at capacity (#{@max}); " \
                "increase max_concurrent_#{@name}_tasks or retry later"
            when :timeout
              remaining = deadline ? (deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)) : nil
              if remaining && remaining <= 0
                raise Phronomy::BackpressureError,
                  "ConcurrencyGate[#{@name}] timed out waiting for a free slot (cap: #{@max})"
              end
              @cond.wait(@mutex, remaining || nil)
              # re-check deadline after wakeup
              if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
                raise Phronomy::BackpressureError,
                  "ConcurrencyGate[#{@name}] timed out waiting for a free slot (cap: #{@max})"
              end
            else # :wait
              @cond.wait(@mutex)
            end
          end
        end
      end

      def _release_slot
        scheduler = Phronomy::Runtime::Scheduler.current
        if scheduler && @coop_signal
          @count -= 1
          scheduler.raise_signal(@coop_signal)
        else
          @mutex.synchronize do
            @count -= 1
            @cond.signal
          end
        end
      end
    end
  end
end
