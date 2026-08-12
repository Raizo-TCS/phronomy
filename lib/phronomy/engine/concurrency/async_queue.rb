# frozen_string_literal: true

module Phronomy
  module Concurrency
    # Thread-safe FIFO queue used at explicit thread boundaries.
    #
    # It intentionally contains no scheduler/Fiber semantics. Cooperative
    # application execution is represented by FSMSession state and EventLoop events.
    class AsyncQueue
      def initialize(max_size: nil)
        @queue = max_size ? SizedQueue.new(max_size) : Thread::Queue.new
      end

      def push(item)
        @queue.push(item)
        self
      end

      def pop(timeout: nil)
        timeout ? @queue.pop(timeout: timeout) : @queue.pop
      end

      def size
        @queue.size
      end

      def empty?
        @queue.empty?
      end

      def close
        @queue.close
        self
      end
    end
  end
end
