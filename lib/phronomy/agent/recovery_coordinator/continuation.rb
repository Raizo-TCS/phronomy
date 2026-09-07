# frozen_string_literal: true

module Phronomy
  module Agent
    class RecoveryCoordinator
      # Both resolution apply and restart use this interpretation of saved facts.
      # Runtime tasks and sessions are projections, never continuation authority.
      # @api private
      module Continuation
        private

        def recovery_action(execution)
          return :framework_tools if framework_batch?(execution)

          case execution.phase.to_sym
          when :recovery_provider_completed
            execution.metadata["framework_calls_pending"] ? :framework_calls : :output
          when :recovery_tools_completed
            execution.metadata["framework_calls_pending"] ? :framework_calls : :followup
          when :recovery_resolved_failed
            :failed_terminal
          else
            :resolution_required
          end
        end

        def continue_recovery_on_event_loop(execution, completion)
          event_loop = Phronomy::Runtime.instance.event_loop
          action = recovery_action(execution)
          if action == :resolution_required
            event_loop.mark_agent_execution_admission(agent.agent_id,
              execution_id: execution.execution_id, state: :recovery_required)
            deliver_resolution_required(execution, coordination_recovery_descriptor(execution))
            completion.complete({execution_id: execution.execution_id,
                                 execution_revision: execution.execution_revision,
                                 recovery: :resolution_required}.freeze)
            return
          end

          observe_recovery_execution(completion, execution)
          main = agent.send(:execution_coordinator_for, agent.__coordination_config)
          projection = event_loop.agent_execution_state(execution.execution_id).runtime_projection
          if action == :failed_terminal
            invocation = build_failed_recovery_invocation(execution, main)
          else
            _manifest, projection = RecoverySupport.materialize_projection(agent, execution.metadata.fetch("manifest_ref"))
            invocation = if action == :framework_tools
              RecoverySupport.build_invocation_for_suspended(agent, execution, projection, main,
                agent.send(:_phronomy_event_listener))
            else
              RecoverySupport.build_chat_for_recovery(agent, execution, projection, main,
                agent.send(:_phronomy_event_listener))
            end
            if execution.phase.to_sym == :recovery_provider_completed
              invocation.output, invocation.usage = RecoverySupport.provider_output_and_usage(agent, execution)
            end
            prepare_saved_provider_calls(execution, invocation) if action == :framework_calls
            AgentInvocationSessionBuilder.send(:output_filtering_action, agent, invocation) if action == :output
          end

          event_loop.replace_agent_execution(execution.execution_id, execution: execution,
            runtime_projection: projection, invocation: invocation, fsm_session_id: nil)
          if action == :failed_terminal
            failure = execution.metadata.dig(RecoverySupport::RECOVERY_METADATA_KEY, "failure") ||
              {"class" => "Phronomy::Error", "message" => "Recovery-resolved failure"}
            main.send(:begin_terminal_commit_on_event_loop,
              event_loop.agent_execution_state(execution.execution_id), completion, invocation,
              RecoverySupport.error_from_failure(failure), fsm_session_id: nil)
            return
          end

          event_loop.mark_agent_execution_admission(agent.agent_id,
            execution_id: execution.execution_id, state: :executing)
          case action
          when :framework_tools
            event_loop.register_agent_completion_waiter(execution.execution_id, completion)
            main.send(:start_framework_tools_on_event_loop, execution.execution_id, completion)
          when :framework_calls
            start_recovery_session(event_loop, main, execution, invocation, completion,
              resume_event: :llm_completed, resume_phase: :calling_llm)
          when :output
            start_recovery_session(event_loop, main, execution, invocation, completion,
              resume_event: :state_completed, resume_phase: :output_filtering)
          when :followup
            start_recovery_session(event_loop, main, execution, invocation, completion,
              resume_event: :state_completed, resume_phase: :recording_tool_results)
          end
        end

        def prepare_saved_provider_calls(execution, invocation)
          record = RecoverySupport.latest_assistant_record(execution)
          message = RubyLLMMaterializer.new(agent: agent, persistence: agent.persistence).materialize_journal_record(record)
          calls = message.tool_calls.respond_to?(:values) ? message.tool_calls.values : Array(message.tool_calls)
          framework_calls = calls.select { |call| agent.__framework_call?(call.name) }
          if framework_calls.empty?
            raise Phronomy::ExecutionRehydrationRequiredError, "Saved framework call wiring is missing"
          end
          invocation.accept_tool_calls!(framework_calls, llm_call_id: record.llm_call_id)
        end

        def build_failed_recovery_invocation(execution, main)
          Phronomy::Agent::AgentInvocation.new(agent: agent, input: nil,
            config: {execution_id: execution.execution_id, phronomy_execution_coordinator: main},
            event_listener: agent.send(:_phronomy_event_listener),
            mode: (execution.metadata[RecoverySupport::INVOCATION_MODE_KEY] || "invoke").to_sym,
            execution_id: execution.execution_id)
        end

        def start_recovery_session(event_loop, main, execution, invocation, completion, resume_event:, resume_phase:)
          session = AgentInvocationSessionBuilder.build_for_resume(agent_invocation: invocation,
            resume_event: resume_event, resume_phase: resume_phase, runtime: Phronomy::Runtime.instance)
          event_loop.replace_agent_execution(execution.execution_id, invocation: invocation, fsm_session_id: session.id)
          event_loop.register_agent_completion_waiter(execution.execution_id, completion)
          source = Phronomy::Task.deferred(name: "#{completion.name}-source")
          source.on_complete do |completed, error|
            main.send(:finish_on_event_loop, execution.execution_id, completion,
              completed || session.context, error, fsm_session_id: session.id)
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
