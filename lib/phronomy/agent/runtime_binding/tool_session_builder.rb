# frozen_string_literal: true

module Phronomy
  module Agent
    # Binds Agent Tool child progress to a concrete FSM session. Session routing
    # is fresh for each incarnation and never replaces a durable Tool identity.
    # @api private
    class ToolSessionBuilder
      def self.build(invocation:, environment:, event_loop:, parent_event_sink:,
        resume_event: nil, resume_phase: nil)
        event_sink = Phronomy::FSMSession::EventSink.new(event_loop: event_loop)
        actions = ToolInvocationActions.build_entry_actions(environment, event_sink, parent_event_sink)
        phase_machine = PhaseMachineBuilder.new(entry_actions: actions,
          transitions: ToolInvocationTransitions, operation_name: "Tool").build

        Phronomy::FSMSession.new(
          context: invocation,
          event_sink: event_sink,
          entry_point: ToolInvocationTransitions::ENTRY_POINT,
          phase_machine_class: phase_machine,
          entry_actions: {},
          auto_state_set: ToolInvocationTransitions::AUTO_STATE_SET,
          declared_states: ToolInvocationTransitions::DECLARED_STATES,
          wait_state_names: ToolInvocationTransitions::WAIT_STATES,
          external_events: ToolInvocationTransitions::EXTERNAL_EVENTS,
          recursion_limit: ToolInvocationTransitions::RECURSION_LIMIT,
          event_loop: event_loop,
          resume_event: resume_event,
          resume_phase: resume_phase
        )
      end
    end
  end
end
