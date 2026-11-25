# frozen_string_literal: true

module Phronomy
  module Agent
    # A process-local capability for one retained pre-dispatch save on the exact
    # original Agent incarnation. Its identities describe responsibility; they
    # do not reconstruct authority in another Runtime or process.
    # @api public
    class DispatchRecovery
      # @api public
      attr_reader :agent_id, :execution_id, :recovery_id, :dispatch_kind

      # @api private
      def initialize(operation)
        @operation = operation
        @agent_id = operation.agent_id.to_s.dup.freeze
        @execution_id = operation.execution_id.to_s.dup.freeze
        @recovery_id = operation.recovery_id.to_s.dup.freeze
        @dispatch_kind = operation.dispatch_kind
        freeze
      end
      private_class_method :new

      private

      attr_reader :operation
    end
  end
end
