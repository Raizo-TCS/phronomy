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
