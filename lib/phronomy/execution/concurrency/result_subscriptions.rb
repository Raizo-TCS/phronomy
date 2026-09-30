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

      def cancellation(token, &callback)
        return unless token

        token.on_cancel(&callback)
        add { token.send(:unregister_cancel_callback, callback) }
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
