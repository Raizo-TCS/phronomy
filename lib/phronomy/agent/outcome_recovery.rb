# frozen_string_literal: true

module Phronomy
  module Agent
    # Process-local reference to one retained Agent final-or-wait save.
    # Its recovery lifetime is distinct from the Agent execution lifetime.
    # Obtain it from a recovery error or pending_outcome_recovery. It neither
    # transfers ownership nor selects a replacement Runtime or Store.
    # @api public
    class OutcomeRecovery
      # Diagnostic identities; possession of their strings is not authority.
      # @api public
      attr_reader :agent_id, :execution_id, :recovery_id

      # @api private
      def initialize(operation)
        @operation = operation
        @agent_id = operation.agent_id.to_s.dup.freeze
        @execution_id = operation.execution_id.to_s.dup.freeze
        @recovery_id = operation.recovery_id.to_s.dup.freeze
        freeze
      end
      private_class_method :new

      private

      attr_reader :operation
    end
  end
end
