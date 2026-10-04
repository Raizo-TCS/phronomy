# frozen_string_literal: true

module Phronomy
  module Agent
    # Adapts the concrete Engine lifecycle and sessions to Agent's connection.
    # Construction alone starts no Runtime resources and creates no registry.
    # @api private
    class EngineEnvironment < ExecutionEnvironment
      def initialize(runtime: Phronomy::Runtime.instance)
        @runtime = runtime
      end

      def registry = ExecutionRegistry.for(@runtime.event_loop)
      def existing_registry = ExecutionRegistry.existing_for(@runtime)

      def ownership
        existing_ownership || @runtime.__register_shutdown_participant(
          key: OwnershipRegistry, participant: OwnershipRegistry.new(environment: self)
        )
      end

      def existing_ownership = @runtime.__shutdown_participant(key: OwnershipRegistry)
      def executing? = @runtime.event_loop.current?
      def session_phase(id) = @runtime.event_loop.fsm_session_state(id)

      def submit(**options, &operation)
        Phronomy::Execution.submit(runtime: @runtime, **options, &operation)
      end

      def build_agent_session(invocation:, resume_event: nil, resume_phase: nil)
        EngineSessionBuilder.build(invocation: invocation, environment: self,
          event_loop: @runtime.event_loop, resume_event: resume_event, resume_phase: resume_phase)
      end

      def build_tool_session(invocation:, parent_sink:, resume_event: nil, resume_phase: nil)
        ToolSessionBuilder.build(invocation: invocation, environment: self,
          event_loop: @runtime.event_loop, parent_event_sink: parent_sink,
          resume_event: resume_event, resume_phase: resume_phase)
      end

      def register_session(session, completion:)
        @runtime.event_loop.register(session, completion: completion)
      end
    end
  end
end
