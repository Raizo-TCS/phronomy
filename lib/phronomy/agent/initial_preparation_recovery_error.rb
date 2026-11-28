# frozen_string_literal: true

module Phronomy
  module Agent
    # The initial request's observation ended while its original Agent retained
    # responsibility. This error proves neither durable admission nor job failure
    # nor a Provider request. A later recovery call creates a new observation.
    # @api public
    class InitialPreparationRecoveryError < Phronomy::Error
      # @api public
      attr_reader :recovery, :agent_id, :execution_id, :recovery_id,
        :original_error

      # @api private
      def initialize(recovery:, error:, original_error: error)
        unless recovery.is_a?(InitialPreparationRecovery)
          raise ArgumentError, "recovery must be an Agent::InitialPreparationRecovery"
        end
        unless [error, original_error].all? { |value| value.nil? || value.is_a?(Exception) }
          raise ArgumentError, "initial preparation recovery causes must be exceptions or nil"
        end
        @recovery = recovery
        @agent_id = recovery.agent_id.to_s.dup.freeze
        @execution_id = recovery.execution_id.to_s.dup.freeze
        @recovery_id = recovery.recovery_id.to_s.dup.freeze
        @operation_error = error
        @original_error = original_error
        super("Agent #{@agent_id.inspect} execution #{@execution_id.inspect} " \
          "initial preparation recovery #{@recovery_id.inspect} requires an explicit " \
          "recovery observation", code: "agent.initial_preparation_recovery")
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
