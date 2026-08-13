# frozen_string_literal: true

module Phronomy
  module Concurrency
    # Cooperative cancellation token for Agent/Tool work.
    class CancellationToken
      # Creates a token that expires after +seconds+ measured with the monotonic clock.
      # @api public
      def self.timeout_after(seconds)
        monotonic_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        new(monotonic_deadline: monotonic_deadline)
      end

      # @param monotonic_deadline [Float, nil] internal monotonic timestamp.
      # @api public
      def initialize(monotonic_deadline: nil)
        @cancelled = false
        @monotonic_deadline = monotonic_deadline
        @mutex = Mutex.new
        @cancel_callbacks = []
      end

      # @api public
      def remaining_monotonic_seconds
        return nil if @monotonic_deadline.nil?

        remaining = @monotonic_deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        [remaining, 0.0].max
      end

      # Registers a callback for explicit cancellation.
      #
      # Deadline expiry by itself only changes {#cancelled?}. Components that need
      # callback delivery for a monotonic deadline must promote that deadline to
      # +cancel!+ through the Runtime timer queue.
      #
      # @return [self]
      # @api public
      def on_cancel(&block)
        raise ArgumentError, "on_cancel requires a block" unless block

        already_cancelled = @mutex.synchronize do
          if @cancelled
            true
          else
            @cancel_callbacks << block
            false
          end
        end
        block.call if already_cancelled
        self
      end

      # Explicitly cancels the token and invokes each currently registered callback
      # once. The callback registry is cleared before callbacks run so completed
      # registrations are not retained for the lifetime of a long-lived token.
      #
      # @return [self]
      # @api public
      def cancel!
        callbacks = @mutex.synchronize do
          return self if @cancelled

          @cancelled = true
          callbacks = @cancel_callbacks
          @cancel_callbacks = []
          callbacks
        end
        callbacks.each(&:call)
        self
      end

      # @api public
      def cancelled?
        return true if @mutex.synchronize { @cancelled }

        !@monotonic_deadline.nil? &&
          Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @monotonic_deadline
      end

      # @api public
      def raise_if_cancelled!(message = "invocation cancelled")
        raise Phronomy::CancellationError, message if cancelled?
      end

      private

      # Removes an explicit-cancellation callback that is no longer needed.
      #
      # This exists so framework wait/operation registrations do not keep their
      # captured state alive when the operation completes before the token is
      # cancelled. It is intentionally not part of the public cancellation API.
      #
      # A concurrent +cancel!+ may already have taken the callback for delivery;
      # callers must therefore make their callback idempotent.
      def unregister_cancel_callback(callback)
        @mutex.synchronize { @cancel_callbacks.delete(callback) }
        self
      end
    end
  end
end
