# frozen_string_literal: true

module Phronomy
  module Agent
    # The approval observation ended while its original owner retained uncertain
    # work. This does not classify the execution as failed or release the job.
    # A later explicit recovery call returns an independent observation.
    # @api public
    class ApprovalRecoveryError < Phronomy::Error
      # @api public
      attr_reader :recovery, :agent_id, :execution_id, :approval_request_id,
        :recovery_id, :approved, :original_error

      # Retains the initial operation error separately from the immediate cause
      # of this observation; neither is reconstructed from saved diagnostics.
      # @api private
      def initialize(recovery:, error:, original_error: error)
        @recovery = recovery
        @agent_id = recovery.agent_id.to_s.dup.freeze
        @execution_id = recovery.execution_id.to_s.dup.freeze
        @approval_request_id = recovery.approval_request_id.to_s.dup.freeze
        @recovery_id = recovery.recovery_id.to_s.dup.freeze
        @approved = recovery.approved
        @operation_error = error
        @original_error = original_error
        super("Agent #{@agent_id.inspect} execution #{@execution_id.inspect} approval " \
          "#{@approval_request_id.inspect} recovery #{@recovery_id.inspect} requires an explicit " \
          "recovery observation", code: "agent.approval_recovery")
      end

      # Preserve the immediate operation error across TaskResult delivery.
      # @return [Exception, nil]
      # @api public
      def cause
        @operation_error || super
      end
    end
  end
end
