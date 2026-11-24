# frozen_string_literal: true

module Phronomy
  module Agent
    # A process-local capability for one retained approval decision on the exact
    # original Agent incarnation. Its identities are diagnostic, not authority
    # to reconstruct the capability in another Runtime or process.
    # @api public
    class ApprovalRecovery
      # @api public
      attr_reader :agent_id, :execution_id, :approval_request_id, :recovery_id, :approved

      # @api private
      def initialize(operation)
        @operation = operation
        @agent_id = operation.agent_id.to_s.dup.freeze
        @execution_id = operation.execution_id.to_s.dup.freeze
        @approval_request_id = operation.approval_request_id.to_s.dup.freeze
        @recovery_id = operation.recovery_id.to_s.dup.freeze
        @approved = operation.approved
        freeze
      end
      private_class_method :new

      private

      attr_reader :operation
    end
  end
end
