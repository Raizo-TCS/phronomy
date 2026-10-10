# frozen_string_literal: true

module Phronomy
  module Integrations
    # Optional transport helper. Payload meaning and destinations belong to the app.
    # @api public
    class OrderedEventDelivery
      class ClosedError < StandardError; end
      class OverflowError < StandardError; end

      # Close and drain after the block, preserving its result or original failure.
      # A flush timeout limits waiting, not an in-flight network request.
      # @api public
      def self.open(deliver:, capacity: 256, batch_size: 32, flush_timeout: 30, prepare_batch: nil)
        raise ArgumentError, "block required" unless block_given?
        reject_event_loop!
        validate_timeout!(flush_timeout)
        raise ArgumentError, "deliver must be callable" unless deliver.respond_to?(:call)
        delivery = new(capacity: capacity, batch_size: batch_size, prepare_batch: prepare_batch, &deliver)
        begin
          yield delivery
        ensure
          primary = $!
          begin
            delivery.close_and_wait(timeout: flush_timeout)
          rescue => secondary
            if primary
              report_secondary(secondary)
            else
              raise
            end
          end
        end
      end

      def self.reject_event_loop!
        if Phronomy::Runtime.in_event_loop_context?
          raise Phronomy::EventLoopReentrancyError, "delivery flush cannot block EventLoop"
        end
      end

      def self.validate_timeout!(timeout)
        valid = timeout.nil? || (timeout.is_a?(Numeric) && timeout.finite? && timeout >= 0)
        raise ArgumentError, "flush timeout must be a finite nonnegative number or nil" unless valid
      end

      def self.report_secondary(error)
        Phronomy.configuration.logger&.error("[OrderedEventDelivery] secondary delivery failure: #{error.class}: #{error.message}")
      rescue => logging_error
        warn "[OrderedEventDelivery] secondary failure: #{error.class}: #{error.message}; logger failed: #{logging_error.class}"
      end
      private_class_method :reject_event_loop!, :validate_timeout!, :report_secondary

      # Construction does not start a worker or create a pool.
      # @api public
      def initialize(capacity: 256, batch_size: 32, prepare_batch: nil, &deliver)
        raise ArgumentError, "deliver block required" unless deliver
        unless capacity.is_a?(Integer) && capacity.positive? && batch_size.is_a?(Integer) && batch_size.positive?
          raise ArgumentError, "capacity and batch_size must be positive Integers"
        end
        raise ArgumentError, "prepare_batch must be callable" if prepare_batch && !prepare_batch.respond_to?(:call)
        @capacity, @batch_size = capacity, batch_size
        @prepare_batch, @deliver = prepare_batch, deliver
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @queue = []
        @accepting = true
        @worker = nil
        @failure = nil
      end

      # Snapshot plain data; admission order is the queue insertion order.
      # Capacity counts queued payloads, excluding the active batch.
      # @api public
      def publish(payload)
        value = immutable_copy(payload)
        ticket = @mutex.synchronize do
          raise @failure if @failure
          raise ClosedError, "event delivery closed" unless @accepting
          raise OverflowError, "event delivery queue full" if @queue.length >= @capacity
          @queue << value
          next nil if @worker
          @worker = {started: false}
        end
        start_drain(ticket) if ticket
        error = @mutex.synchronize { @failure }
        raise error if error
        self
      rescue => error
        # Listener dispatch can log an exception and continue. Retain the failure
        # for close while continuing to drain already accepted work if possible.
        @mutex.synchronize do
          @failure ||= error
          @accepting = false
        end
        raise
      end

      # External callers only. Concurrent close calls observe the same drain.
      # Timeout does not abort a network operation or settle the worker's result.
      # @api public
      def close_and_wait(timeout: nil)
        self.class.send(:reject_event_loop!)
        self.class.send(:validate_timeout!, timeout)
        deadline = timeout && monotonic_now + timeout
        @mutex.synchronize do
          @accepting = false
          while @worker
            remaining = deadline && deadline - monotonic_now
            raise Phronomy::TimeoutError, "event delivery flush timed out" if remaining && remaining <= 0
            @condition.wait(@mutex, remaining)
          end
          raise @failure if @failure
        end
        self
      end

      private

      def start_drain(ticket)
        Phronomy::Blocking.call_async do
          started = @mutex.synchronize do
            ticket[:started] = true if @worker.equal?(ticket)
          end
          if started
            begin
              drain(ticket)
            rescue => error
              fail_worker(ticket, error)
            ensure
              finish_worker(ticket)
            end
          end
        end.on_complete do |_value, error|
          fail_worker(ticket, error) if error
        end
      rescue => error
        fail_worker(ticket, error)
      end

      def drain(ticket)
        loop do
          batch = @mutex.synchronize do
            if @queue.empty?
              # Publish must observe queue emptiness and ownership release together.
              release_worker(ticket)
              nil
            else
              @queue.shift(@batch_size)
            end
          end
          return unless batch
          prepared = @prepare_batch ? @prepare_batch.call(batch.freeze) : batch
          raise ArgumentError, "prepare_batch must return an Array" unless prepared.is_a?(Array)
          immutable_copy(prepared).each { |payload| @deliver.call(payload) }
        end
      end

      def fail_worker(ticket, error)
        @mutex.synchronize do
          @failure ||= error
          @accepting = false
          @queue.clear
          # Logical cancellation can precede physical worker exit. Keep waiting
          # for a started delivery; never mistake settled TaskResult for exit.
          release_worker(ticket) unless ticket[:started]
        end
      end

      def finish_worker(ticket)
        @mutex.synchronize { release_worker(ticket) }
      end

      def release_worker(ticket)
        return unless @worker.equal?(ticket)
        @worker = nil
        @condition.broadcast
      end

      def immutable_copy(value, ancestors = {})
        case value
        when Hash, Array
          raise ArgumentError, "event payload must contain acyclic plain data" if ancestors[value.object_id]
          path = ancestors.merge(value.object_id => true)
          if value.is_a?(Hash)
            value.to_h { |key, child| [immutable_copy(key, path), immutable_copy(child, path)] }.freeze
          else
            value.map { |child| immutable_copy(child, path) }.freeze
          end
        when String then value.dup.freeze
        when Integer, Symbol, TrueClass, FalseClass, NilClass then value
        when Float
          raise ArgumentError, "event payload numbers must be finite" unless value.finite?
          value
        else
          raise ArgumentError, "event payload must contain plain data: #{value.class}"
        end
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
