# frozen_string_literal: true

module Phronomy
  # Process-local reference to one retained Workflow terminal operation.
  # Obtain this from a recovery error or pending_terminal_recovery; it is not
  # a serializable ticket and does not select a replacement Runtime.
  # @api public
  class WorkflowTerminalRecovery
    # @return [String]
    # @api public
    attr_reader :workflow_instance_id, :recovery_id

    # @api private
    def initialize(operation)
      @operation = operation
      @workflow_instance_id = operation.workflow_instance_id.dup.freeze
      @recovery_id = operation.recovery_id.dup.freeze
      freeze
    end
    private_class_method :new

    private

    attr_reader :operation
  end
end
