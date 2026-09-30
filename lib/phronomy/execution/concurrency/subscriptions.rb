# frozen_string_literal: true

module Phronomy
  module Concurrency
    # Services promotes deadlines into control notifications.
    # @api private
    class Subscriptions < ResultSubscriptions
      def cancellation(token, &callback)
        return unless token

        super
        remaining = token.remaining_monotonic_seconds
        after(remaining, &callback) if !token.cancelled? && remaining
      end

      def after(seconds, &callback)
        if seconds <= 0
          callback.call
          return
        end
        add(&Phronomy::Execution.after(seconds, &callback))
      end
    end
  end
end
