# frozen_string_literal: true

module Phronomy
  module Agent
    # Actual-terminal specialization of the shared retained outcome mechanism.
    # Existing terminal capabilities never expose coordination or approval waits.
    # @api private
    class TerminalRecoveryOperation < OutcomeRecoveryOperation
      def recovery_kind = :terminal

      private

      def recovery_class = TerminalRecovery
      def recovery_result_class = TerminalRecoveryResult
      def recovery_error_class = TerminalRecoveryError
      def receipt_details(_saved_outcome, _approval_request) = {}

      def apply_to_owner(coordinator, outcome)
        coordinator.send(:apply_retained_terminal_on_event_loop, self, outcome)
      end
    end
  end
end
