# frozen_string_literal: true

module Phronomy
  module Concurrency
    # Disposable registrations. add also handles synchronous notification during
    # registration: cleanup added after close is performed immediately.
    # @api private
    class Subscriptions
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
        remaining = token.remaining_monotonic_seconds
        if token.cancelled?
          callback.call
        elsif remaining
          after(remaining, &callback)
        end
      end

      def after(seconds, &callback)
        if seconds <= 0
          callback.call
          return
        end
        timer = Phronomy::Runtime.instance.timer_queue
        timer.schedule(seconds: seconds, &callback)
        add { timer.cancel(callback) }
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
