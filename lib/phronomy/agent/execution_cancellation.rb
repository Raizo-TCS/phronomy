# frozen_string_literal: true

module Phronomy
  module Agent
    # Wakes the existing execution cancellation token. Durable owners record the
    # request first; this notification is replaceable after Runtime loss.
    # @api private
    class ExecutionCancellation
      Command = Data.define(:coordinator, :execution_id, :agent_id)
      private_constant :Command

      def self.signal(execution_id, agent_id)
        command = Command.new(coordinator: new, execution_id: execution_id, agent_id: agent_id)
        Phronomy::Runtime.instance.event_loop.post(Phronomy::Event.new(type: :agent_terminal_ready,
          target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID, payload: {command: command}))
      end

      def deliver_on_event_loop(command)
        state = Phronomy::Runtime.instance.event_loop.agent_execution_state(command.execution_id)
        return unless state && state.agent.agent_id == command.agent_id
        state.invocation&.config&.fetch(:cancellation_token, nil)&.cancel!
      end
    end
  end
end
