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
  #   Task.spawn { queue.push(expensive_io()) }
  #   value = queue.pop   # blocks until the producer pushes
  class AsyncQueue
    # @param max_size [Integer, nil] optional upper bound on queue depth.
    #   When set, {#push} blocks the caller until a slot is available.
    # @api private
    def initialize(max_size: nil)
      @queue = max_size ? SizedQueue.new(max_size) : Thread::Queue.new
      @max_size = max_size
    end

    # Enqueues +item+.  Blocks when +max_size+ is set and the queue is full.
    # In a cooperative scheduler context, also notifies any suspended +pop+ caller.
    # @param item [Object] value to enqueue
    # @return [self]
    # @api private
    def push(item)
      @queue.push(item)
      scheduler = Phronomy::Runtime::Scheduler.current
      scheduler.raise_signal(@coop_signal) if scheduler && @coop_signal
      self
    end

    # Dequeues and returns the next item.
    # In a cooperative scheduler context, suspends the current Fiber (yielding
    # control back to the scheduler) rather than blocking the OS thread.
    # When +timeout+ is given, returns +nil+ if no item arrives within that many
    # seconds.  (Requires Ruby 3.2+, which added +Thread::Queue#pop(timeout:)+.)
    # @param timeout [Numeric, nil] seconds to wait before returning nil
    # @return [Object, nil] the next item, or nil when timeout expires
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
    # @param scheduler [Runtime::Scheduler]
    # @param timeout [Numeric, nil]
    # @return [Object, nil]
    def _pop_cooperative(scheduler, timeout:)
      @coop_signal ||= scheduler.new_signal
      deadline = timeout ? (scheduler.virtual_time + timeout) : nil

      loop do
        return @queue.pop(timeout: 0) unless @queue.empty?
        return nil if deadline && scheduler.virtual_time >= deadline
        scheduler.wait_for_signal(@coop_signal)
        return nil if deadline && scheduler.virtual_time >= deadline
      end
    end
  end
end
