# frozen_string_literal: true

module Phronomy
  module Agent
    # Engine-only construction. State vocabulary, ordered guards and entry
    # operations are supplied by the Agent framework, not defined here.
    # @api private
    class EngineSessionBuilder
      def self.build(invocation:, environment:, event_loop:, resume_event: nil, resume_phase: nil)
        event_sink = Phronomy::FSMSession::EventSink.new(event_loop: event_loop)
        invocation.bind_event_sink!(event_sink)
        actions = InvocationActions.build_entry_actions(invocation.agent,
          environment, mode: invocation.mode, event_sink: event_sink)
        phase_machine = PhaseMachineBuilder.new(entry_actions: actions).build

        Phronomy::FSMSession.new(
          context: invocation,
          event_sink: event_sink,
          entry_point: InvocationTransitions::ENTRY_POINT,
          phase_machine_class: phase_machine,
          entry_actions: {},
          auto_state_set: InvocationTransitions::AUTO_STATE_SET,
          declared_states: InvocationTransitions::DECLARED_STATES,
          wait_state_names: InvocationTransitions::WAIT_STATES,
          external_events: InvocationTransitions::EXTERNAL_EVENTS,
          recursion_limit: InvocationTransitions.recursion_limit(invocation.agent.class.max_iterations),
          event_loop: event_loop,
          resume_event: resume_event,
          resume_phase: resume_phase
        )
      end
    end
  end
end
