# frozen_string_literal: true

module Phronomy
  module Agent
    # Classifies failed execution outcomes without owning persistence or delivery.
    # @api private
    module ExecutionFailure
      # @api private
      def self.status_for(error)
        if defined?(Phronomy::CancellationError) && error.is_a?(Phronomy::CancellationError)
          return :cancelled
        end
        if defined?(Phronomy::FilterBlockError) && error.is_a?(Phronomy::FilterBlockError)
          return :blocked
        end

        :failed
      end

      # @api private
      def self.journal_kind_for(status)
        {
          cancelled: :execution_cancelled,
          blocked: :execution_blocked,
          failed: :execution_failed
        }.fetch(status)
      end
    end
  end
end
