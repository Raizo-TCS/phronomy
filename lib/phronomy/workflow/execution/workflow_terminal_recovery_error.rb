# frozen_string_literal: true

require_relative "../../common/error"

module Phronomy
  # The terminal persistence obligation needs an explicit recovery observation.
  # This error does not establish business failure or release Workflow ownership.
  # The capability is process-local and belongs to the original Workflow.
  # @api public
  class WorkflowTerminalRecoveryError < Phronomy::Error
    # @api public
    attr_reader :recovery, :workflow_instance_id, :recovery_id, :original_error

    # Constructed by the owner after retaining the terminal obligation.
    # @api private
    def initialize(recovery:, error:, original_error: error)
      @recovery = recovery
      @workflow_instance_id = recovery.workflow_instance_id.to_s.dup.freeze
      @recovery_id = recovery.recovery_id.to_s.dup.freeze
      @operation_error = error
      @original_error = original_error
      super("Workflow #{@workflow_instance_id.inspect} terminal recovery #{@recovery_id.inspect} " \
        "requires an explicit reconciliation observation", code: "workflow.terminal_recovery")
    end

    # Preserve the immediate operation failure even when delivered through a
    # TaskResult rather than raised inside its original rescue clause.
    # @return [Exception, nil]
    # @api public
    def cause
      @operation_error || super
    end
  end
end
