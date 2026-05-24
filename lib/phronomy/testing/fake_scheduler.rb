# frozen_string_literal: true

module Phronomy
  module Testing
    # A deterministic event dispatcher for use in tests.
    #
    # Wraps a {Thread::Queue} and dispatches events one at a time via {#tick}
    # or drains all pending events via {#tick_until_idle}.  Tests can inspect
    # queue depth and verify event ordering without wall-clock sleeps.
    #
    # @example
    #   scheduler = Phronomy::Testing::FakeScheduler.new
    #   scheduler.post(:a)
    #   scheduler.post(:b)
    #   scheduler.queue_depth   # => 2
    #   scheduler.tick          # dispatches :a
    #   scheduler.queue_depth   # => 1
    #   scheduler.tick_until_idle
    #   scheduler.dispatched    # => [:a, :b]
    class FakeScheduler
      # @return [Array] all events dispatched so far (in order)
      attr_reader :dispatched

      def initialize
        @queue = Thread::Queue.new
        @dispatched = []
        @handlers = {}
      end

      # Enqueue an event for later dispatch.
      #
      # @param event [Object]
      # @return [self]
      def post(event)
        @queue.push(event)
        self
      end

      # Dispatch the next queued event.
      # Calls the registered handler (if any) and records the event.
      # Returns the dispatched event, or +nil+ if the queue is empty.
      #
      # @return [Object, nil]
      def tick
        return nil if @queue.empty?

        event = @queue.pop(true) rescue nil
        return nil unless event

        @dispatched << event
        handler = @handlers[event.class] || @handlers[:any]
        handler&.call(event)
        event
      end

      # Dispatch events until the queue is empty.
      # Bounded by +max_ticks+ to prevent infinite loops.
      #
      # @param max_ticks [Integer]
      # @return [Integer] number of events dispatched
      def tick_until_idle(max_ticks: 1000)
        count = 0
        while !@queue.empty? && count < max_ticks
          tick
          count += 1
        end
        count
      end

      # Returns the number of events waiting to be dispatched.
      # @return [Integer]
      def queue_depth
        @queue.size
      end

      # Register a handler block for events of the given class.
      # Use +:any+ to handle all event types.
      #
      # @param klass [Class, :any]
      # @yield [event]
      # @return [self]
      def on(klass, &block)
        @handlers[klass] = block
        self
      end

      # Returns true when the queue is empty.
      # @return [Boolean]
      def idle?
        @queue.empty?
      end
    end
  end
end
