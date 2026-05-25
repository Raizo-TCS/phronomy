# frozen_string_literal: true

module Phronomy
  # A thread-safe FIFO queue for passing values between concurrent tasks.
  #
  # Wraps +Thread::Queue+ so that callers do not need to reference the Ruby
  # standard-library type directly.  A future implementation may replace the
  # backing primitive without changing call sites.
  #
  # @example Producer / consumer
  #   queue = Phronomy::AsyncQueue.new
  #   Runtime.instance.spawn { queue.push(expensive_io()) }
  #   value = queue.pop   # blocks until the producer pushes
  # @api private
  class AsyncQueue
    # @param max_size [Integer, nil] optional upper bound on queue depth.
    #   When set, {#push} blocks the caller until a slot is available.
    # @api private
    def initialize(max_size: nil)
      @queue = max_size ? SizedQueue.new(max_size) : Thread::Queue.new
      @max_size = max_size
    end

    # Enqueues +item+.
    # In a cooperative scheduler context with a bounded queue (max_size:), suspends
    # the current Fiber via a scheduler signal when the queue is full rather than
    # blocking the OS thread.  Without a scheduler, falls back to the standard
    # SizedQueue blocking behaviour.
    # @param item [Object] value to enqueue
    # @return [self]
    # @api private
    def push(item)
      scheduler = Phronomy::Runtime::Scheduler.current
      if scheduler && @max_size
        _push_cooperative(scheduler, item)
      else
        @queue.push(item)
        scheduler.raise_signal(@coop_signal) if scheduler && @coop_signal
      end
      self
    end

    # Dequeues and returns the next item.
    # In a cooperative scheduler context, suspends the current Fiber (yielding
    # control back to the scheduler) rather than blocking the OS thread.
    #
    # When +timeout+ is given the semantics depend on the active backend:
    #
    # * **Thread backend** (`:thread`) — uses real wall-clock time via
    #   +Thread::Queue#pop(timeout:)+.  Requires Ruby 3.2+.
    #   Returns +nil+ if no item arrives within the specified number of real seconds.
    # * **DeterministicScheduler / `:fiber` backend** — uses the scheduler's
    #   *virtual time* (+scheduler.virtual_time+).  The timeout elapses only when
    #   the virtual clock is advanced (e.g. via {Phronomy::Testing::FakeClock#advance}).
    #   In tests this means the timeout is fully deterministic and does not depend on
    #   actual elapsed wall time.  However, in production `:fiber` mode the timeout
    #   may never expire unless the scheduler explicitly advances virtual time.
    #
    # @note The `:fiber` backend is **EXPERIMENTAL**.  Real-time timeout behaviour
    #   in production workloads is not guaranteed and may differ from wall-clock
    #   expectations.
    # @note **Cooperative timeout limitation**: on the cooperative path, the
    #   deadline is re-checked *after* a wake-up signal arrives.  If virtual time
    #   has already passed the deadline when the consumer is woken by a producer
    #   push, the consumer returns +nil+ rather than the pushed item.  Without any
    #   wake-up signal the waiting Fiber remains suspended even after
    #   +scheduler.advance+ — the timeout does not self-fire.
    # @param timeout [Numeric, nil] seconds to wait before returning +nil+.
    #   Semantics are wall-clock on `:thread` and virtual-time on `:fiber`.
    # @return [Object, nil] the next item, or +nil+ when timeout expires
    # @api private
    def pop(timeout: nil)
      scheduler = Phronomy::Runtime::Scheduler.current
      if scheduler
        _pop_cooperative(scheduler, timeout: timeout)
      elsif timeout
        @queue.pop(timeout: timeout)
      else
        @queue.pop
      end
    end

    # Returns the current number of items in the queue.
    # @return [Integer]
    # @api private
    def size
      @queue.size
    end

    # Returns +true+ when the queue contains no items.
    # @return [Boolean]
    # @api private
    def empty?
      @queue.empty?
    end

    # Closes the queue.  Subsequent {#pop} calls raise +ClosedQueueError+.
    # @return [self]
    # @api private
    def close
      @queue.close
      self
    end

    private

    # Cooperative pop for DeterministicScheduler context.
    # Suspends the current Fiber via the scheduler's signal mechanism rather than
    # blocking the OS thread.  Because cooperative mode is single-threaded, the
    # empty?/pop pair is race-free (no other Fiber can run between the two calls).
    # After dequeuing, notifies any push-waiter so that a backpressure-suspended
    # producer can be unblocked.
    # @api private
    # @param scheduler [Runtime::Scheduler]
    # @param timeout [Numeric, nil]
    # @return [Object, nil]
    def _pop_cooperative(scheduler, timeout:)
      @coop_signal ||= scheduler.new_signal
      deadline = timeout ? (scheduler.virtual_time + timeout) : nil

      loop do
        unless @queue.empty?
          item = @queue.pop(timeout: 0)
          # Notify a push-waiter (bounded queue) that a slot opened up.
          scheduler.raise_signal(@push_signal) if @push_signal
          return item
        end
        return nil if deadline && scheduler.virtual_time >= deadline
        scheduler.wait_for_signal(@coop_signal)
        return nil if deadline && scheduler.virtual_time >= deadline
      end
    end

    # Cooperative push for DeterministicScheduler context with a bounded queue.
    # Suspends the current Fiber via a scheduler signal when the queue is full,
    # rather than blocking the OS thread.
    # @api private
    # @param scheduler [Runtime::Scheduler]
    # @param item [Object]
    # @return [void]
    def _push_cooperative(scheduler, item)
      @push_signal ||= scheduler.new_signal

      loop do
        unless @queue.size >= @max_size
          @queue.push(item)
          # Notify any pop-waiter that an item is now available.
          scheduler.raise_signal(@coop_signal) if @coop_signal
          return
        end
        scheduler.wait_for_signal(@push_signal)
      end
    end
  end
end
