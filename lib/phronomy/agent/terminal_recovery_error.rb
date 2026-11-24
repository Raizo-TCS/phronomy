# frozen_string_literal: true

module Phronomy
  module Agent
    # The observation ended while its Agent still owns a terminal obligation.
    # This error does not classify the job as failed or cancel its saved work.
    # A later explicit recovery call returns an independent observation.
    # @api public
    class TerminalRecoveryError < Phronomy::Error
      # @api public
      attr_reader :recovery, :agent_id, :execution_id, :recovery_id, :original_error

      # Constructed only after retaining responsibility for this operation.
      # original_error is the original persistence/operation error, not a
      # diagnostic reconstructed into an arbitrary execution exception.
      # @api private
      def initialize(recovery:, error:, original_error: error)
        @recovery = recovery
        @agent_id = recovery.agent_id.to_s.dup.freeze
        @execution_id = recovery.execution_id.to_s.dup.freeze
        @recovery_id = recovery.recovery_id.to_s.dup.freeze
        @operation_error = error
        @original_error = original_error
        super("Agent #{@agent_id.inspect} execution #{@execution_id.inspect} terminal recovery " \
          "#{@recovery_id.inspect} requires an explicit recovery observation", code: "agent.terminal_recovery")
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
