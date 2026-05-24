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
    def initialize(max_size: nil)
      @queue    = max_size ? SizedQueue.new(max_size) : Thread::Queue.new
      @max_size = max_size
    end

    # Enqueues +item+.  Blocks when +max_size+ is set and the queue is full.
    # @param item [Object] value to enqueue
    # @return [self]
    def push(item)
      @queue.push(item)
      self
    end

    # Dequeues and returns the next item.  Blocks until an item is available.
    # When +timeout+ is given, returns +nil+ if no item arrives within that many
    # seconds.  (Requires Ruby 3.2+, which added +Thread::Queue#pop(timeout:)+.)
    # @param timeout [Numeric, nil] seconds to wait before returning nil
    # @return [Object, nil] the next item, or nil when timeout expires
    def pop(timeout: nil)
      if timeout
        @queue.pop(timeout: timeout)
      else
        @queue.pop
      end
    end

    # Returns the current number of items in the queue.
    # @return [Integer]
    def size
      @queue.size
    end

    # Returns +true+ when the queue contains no items.
    # @return [Boolean]
    def empty?
      @queue.empty?
    end

    # Closes the queue.  Subsequent {#pop} calls raise +ClosedQueueError+.
    # @return [self]
    def close
      @queue.close
      self
    end
  end
end
