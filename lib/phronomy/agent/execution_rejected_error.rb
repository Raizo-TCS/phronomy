# frozen_string_literal: true

module Phronomy
  module Agent
    # This reserved start was rejected before durable admission was attempted.
    # Another caller may have started the same identity; coordinating owners
    # must observe it under their reservation guard before ending their own run.
    # @api public
    class ExecutionRejectedError < Phronomy::Error
      attr_reader :agent_id, :execution_id

      def initialize(message, agent_id:, execution_id:)
        @agent_id = agent_id.to_s.dup.freeze
        @execution_id = execution_id.to_s.dup.freeze
        super(message, code: "agent.execution_rejected")
      end

      # Preserve the original validation diagnostic without changing ordinary
      # invocation errors or treating cancellation as an input rejection.
      # @api private
      def self.from_error(error, agent_id:, execution_id:)
        return error unless execution_id
        return error if error.is_a?(Phronomy::CancellationError) || error.is_a?(Phronomy::TimeoutError)

        begin
          raise new(error.message, agent_id: agent_id, execution_id: execution_id), cause: error
        rescue ExecutionRejectedError => rejected
          rejected.set_backtrace(error.backtrace)
          rejected
        end
      end
    end
  end
end
