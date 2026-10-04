# frozen_string_literal: true

module Phronomy
  module Agent
    # Wakes the existing execution cancellation token. Durable owners record the
    # request first; this notification is replaceable after Runtime loss.
    # @api private
    class ExecutionCancellation
      Command = Data.define(:coordinator, :execution_id, :agent_id)
      private_constant :Command

      def self.signal(execution_id, agent_id, environment:)
        command = Command.new(coordinator: new(environment), execution_id: execution_id, agent_id: agent_id)
        environment.registry.post(command)
      end

      def initialize(environment)
        @environment = environment
      end

      def deliver_on_event_loop(command)
        state = @environment.registry.agent_execution_state(command.execution_id)
        return unless state && state.agent.agent_id == command.agent_id
        state.invocation&.config&.fetch(:cancellation_token, nil)&.cancel!
      end
    end
  end
end
