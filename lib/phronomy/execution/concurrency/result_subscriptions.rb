# frozen_string_literal: true

module Phronomy
  module Concurrency
    # Completion and explicit-cancellation subscriptions. No timer acquisition.
    # @api private
    class ResultSubscriptions
      def initialize
        @mutex = Mutex.new
        @closed = false
        @cleanup = []
      end

      def add(&cleanup)
        dispose = @mutex.synchronize do
          if @closed
            true
          else
            @cleanup << cleanup
            false
          end
        end
        cleanup.call if dispose
      end

      def result(result, &callback)
        result.on_complete(&callback)
        add { result.__unsubscribe(callback) }
      end

      # Own the lifetime of explicit-cancellation notifications only. An elapsed
      # deadline is not promoted to a notification here. close can race delivery:
      # a callback already taken by cancel! may still run, as with the token API.
      # Registration may deliver inline and close this collection before add;
      # add then immediately disposes the completed registration.
      # @api private
      def explicit_cancellation(token, &callback)
        return unless token

        token.on_cancel(&callback)
        add { token.send(:unregister_cancel_callback, callback) }
      end

      def cancellation(token, &callback)
        return unless token

        explicit_cancellation(token, &callback)
        callback.call if token.cancelled?
      end

      def close
        cleanup = @mutex.synchronize do
          return if @closed

          @closed = true
          current = @cleanup
          @cleanup = []
          current
        end
        cleanup.each(&:call)
      end
    end
  end
end
