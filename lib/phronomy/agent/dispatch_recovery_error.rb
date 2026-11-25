# frozen_string_literal: true

module Phronomy
  module Agent
    # The caller's execution observation ended while its original Agent retained
    # pre-dispatch responsibility. This does not classify the job as failed or
    # prove that an external request occurred. Recovery is a new observation.
    # @api public
    class DispatchRecoveryError < Phronomy::Error
      # @api public
      attr_reader :recovery, :agent_id, :execution_id, :recovery_id,
        :dispatch_kind, :original_error

      # @api private
      def initialize(recovery:, error:, original_error: error)
        @recovery = recovery
        @agent_id = recovery.agent_id.to_s.dup.freeze
        @execution_id = recovery.execution_id.to_s.dup.freeze
        @recovery_id = recovery.recovery_id.to_s.dup.freeze
        @dispatch_kind = recovery.dispatch_kind
        @operation_error = error
        @original_error = original_error
        super("Agent #{@agent_id.inspect} execution #{@execution_id.inspect} " \
          "#{@dispatch_kind} dispatch recovery #{@recovery_id.inspect} requires an explicit " \
          "recovery observation", code: "agent.dispatch_recovery")
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
