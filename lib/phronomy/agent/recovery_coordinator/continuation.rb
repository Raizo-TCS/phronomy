# frozen_string_literal: true

module Phronomy
  module Agent
    class RecoveryCoordinator
      # Continuation portion of durable Agent Recovery.
      # @api private
      module Continuation
        private

        def continue_provider_completed_after_resolution(
          event_loop,
          old_state,
          execution,
          completion
        )
          manifest_ref = execution.metadata.fetch(
            "manifest_ref"
          )
          _manifest, projection =
            RecoverySupport.materialize_projection(
              agent,
              manifest_ref
            )
          main = agent.send(:execution_coordinator)
          invocation =
            RecoverySupport.build_chat_for_recovery(
              agent,
              execution,
              projection,
              main,
              agent.send(:_phronomy_event_listener)
            )
          output, usage =
            RecoverySupport.provider_output_and_usage(
              agent,
              execution
            )
          invocation.output = output
          invocation.usage = usage
          AgentInvocationSessionBuilder.send(
            :output_filtering_action,
            agent,
            invocation
          )

          event_loop.replace_agent_execution(
            execution.execution_id,
            execution: execution,
            runtime_projection: projection,
            invocation: invocation,
            fsm_session_id: nil
          )
          event_loop.mark_agent_execution_admission(
            agent.agent_id,
            execution_id: execution.execution_id,
            state: :executing
          )
          start_output_completion_session(
            event_loop,
            main,
            execution,
            invocation,
            completion
          )
        end

        def continue_tools_completed_after_resolution(
          event_loop,
          old_state,
          execution,
          completion
        )
          manifest_ref = execution.metadata.fetch(
            "manifest_ref"
          )
          _manifest, projection =
            RecoverySupport.materialize_projection(
              agent,
              manifest_ref
            )
          main = agent.send(:execution_coordinator)
          invocation =
            RecoverySupport.build_chat_for_recovery(
              agent,
              execution,
              projection,
              main,
              agent.send(:_phronomy_event_listener)
            )
          event_loop.replace_agent_execution(
            execution.execution_id,
            execution: execution,
            runtime_projection: projection,
            invocation: invocation,
            fsm_session_id: nil
          )
          event_loop.mark_agent_execution_admission(
            agent.agent_id,
            execution_id: execution.execution_id,
            state: :executing
          )
          start_followup_session(
            event_loop,
            main,
            execution,
            invocation,
            completion
          )
        end

        def continue_failed_after_resolution(
          event_loop,
          old_state,
          execution,
          completion,
          failure
        )
          main = agent.send(:execution_coordinator)
          invocation = Phronomy::Agent::AgentInvocation.new(
            agent: agent,
            input: nil,
            config: {
              execution_id: execution.execution_id,
              phronomy_execution_coordinator: main
            },
            event_listener:
              agent.send(:_phronomy_event_listener),
            mode: (
              execution.metadata[
                RecoverySupport::INVOCATION_MODE_KEY
              ] || "invoke"
            ).to_sym,
            execution_id: execution.execution_id
          )
          event_loop.replace_agent_execution(
            execution.execution_id,
            execution: execution,
            invocation: invocation,
            fsm_session_id: nil
          )
          state = event_loop.agent_execution_state(
            execution.execution_id
          )
          main.send(
            :begin_terminal_commit_on_event_loop,
            state,
            completion,
            invocation,
            RecoverySupport.error_from_failure(failure),
            fsm_session_id: nil
          )
        end

        def start_output_completion_session(
          event_loop,
          main,
          execution,
          invocation,
          completion
        )
          session =
            AgentInvocationSessionBuilder.build_for_resume(
              agent_invocation: invocation,
              resume_event: :state_completed,
              resume_phase: :output_filtering,
              runtime: Phronomy::Runtime.instance
            )
          event_loop.replace_agent_execution(
            execution.execution_id,
            invocation: invocation,
            fsm_session_id: session.id
          )
          event_loop.register_agent_completion_waiter(
            execution.execution_id,
            completion
          )
          source = Phronomy::Task.deferred(
            name: "#{completion.name}-source"
          )
          source.on_complete do |completed, error|
            main.send(
              :finish_on_event_loop,
              execution.execution_id,
              completion,
              completed || session.context,
              error,
              fsm_session_id: session.id
            )
          end
          event_loop.register(session, completion: source)
        end

        def start_followup_session(
          event_loop,
          main,
          execution,
          invocation,
          completion
        )
          session =
            AgentInvocationSessionBuilder.build_for_resume(
              agent_invocation: invocation,
              resume_event: :state_completed,
              resume_phase: :recording_tool_results,
              runtime: Phronomy::Runtime.instance
            )
          event_loop.replace_agent_execution(
            execution.execution_id,
            invocation: invocation,
            fsm_session_id: session.id
          )
          event_loop.register_agent_completion_waiter(
            execution.execution_id,
            completion
          )
          source = Phronomy::Task.deferred(
            name: "#{completion.name}-source"
          )
          source.on_complete do |completed, error|
            main.send(
              :finish_on_event_loop,
              execution.execution_id,
              completion,
              completed || session.context,
              error,
              fsm_session_id: session.id
            )
          end
          event_loop.register(session, completion: source)
        end

        def deliver_resolution_required(execution, descriptor)
          unless descriptor
            raise Phronomy::ExecutionRehydrationRequiredError,
              "Recovery state has no current unresolved subject"
          end
          listener = agent.send(:_phronomy_event_listener)
          unless listener
            raise Phronomy::ConfigurationError,
              "Recovery resolution requires an Agent on_event listener"
          end
          payload = RecoverySupport.event_payload(
            execution,
            descriptor
          )
          callback_error = agent.send(
            :_deliver_stream_event,
            listener,
            StreamEvent.new(
              type: :recovery_resolution_required,
              payload: payload
            )
          )
          if callback_error
            raise agent.send(
              :_build_stream_callback_error,
              event_type: :recovery_resolution_required,
              callback_error: callback_error,
              result: payload
            )
          end
          nil
        end
      end
    end
  end
end
