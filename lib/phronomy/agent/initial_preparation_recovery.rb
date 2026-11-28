# frozen_string_literal: true

module Phronomy
  module Agent
    # A process-local capability for one initial request and its original owner.
    # The same capability spans admission, activation and failure-save stages.
    # Its execution identity does not by itself prove durable admission or confer
    # authority on another Agent incarnation, Runtime or process.
    # @api public
    class InitialPreparationRecovery
      # @api public
      attr_reader :agent_id, :execution_id, :recovery_id

      # @api private
      def initialize(operation)
        @operation = operation
        @agent_id = operation.agent_id.to_s.dup.freeze
        @execution_id = operation.execution_id.to_s.dup.freeze
        @recovery_id = operation.recovery_id.to_s.dup.freeze
        if [@agent_id, @execution_id, @recovery_id].any?(&:empty?)
          raise ArgumentError, "Initial preparation recovery identities must not be empty"
        end
        freeze
      end
      private_class_method :new

      private

      attr_reader :operation
    end
  end
end
