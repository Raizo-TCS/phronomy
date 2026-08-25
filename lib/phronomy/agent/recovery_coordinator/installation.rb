# frozen_string_literal: true

module Phronomy
  module Agent
    class RecoveryCoordinator
      # Installation portion of durable Agent Recovery.
      # @api private
      module Installation
        private

        def prepare_plan(execution)
          root = agent.agent_root
          manifest_ref = execution.metadata["manifest_ref"]
          base_ref = execution.metadata["base_manifest_ref"] ||
            manifest_ref
          manifest = base_manifest = projection = nil
          if manifest_ref
            manifest, projection =
              RecoverySupport.materialize_projection(
                agent,
                manifest_ref
              )
            base_manifest = if base_ref.to_s == manifest_ref.to_s
              manifest
            else
              RecoverySupport.manifest_from_ref(agent, base_ref)
            end
          end

          classification = classify(execution)
          RecoveryPlan.new(
            execution: execution,
            root: root,
            manifest: manifest,
            base_manifest: base_manifest,
            projection: projection,
            classification: classification
          )
        end

        def classify(execution)
          if execution.status == :suspended &&
              execution.phase.to_sym == :approval
            return Phronomy::Recovery::Classification.new(
              disposition: Phronomy::Recovery::RESUMABLE,
              reason: :approval_wait,
              facts: {
                approval_request_id:
                  execution.approval_request &&
                    (
                      execution.approval_request["id"] ||
                      execution.approval_request[:id]
                    )
              }.compact
            )
          end

          case execution.phase.to_sym
          when :recovery_provider_completed,
            :recovery_tools_completed,
            :recovery_resolved_failed
            return Phronomy::Recovery::Classification.new(
              disposition: Phronomy::Recovery::RESUMABLE,
              reason: execution.phase
            )
          when :resuming
            approved = execution.approval_request &&
              (
                execution.approval_request["approved"] ||
                execution.approval_request[:approved]
              )
            unless approved
              return Phronomy::Recovery::Classification.new(
                disposition: Phronomy::Recovery::RESUMABLE,
                reason: :approval_rejection_committed
              )
            end
          end

          descriptor = RecoverySupport.recovery_descriptor(
            execution
          )
          if descriptor
            return Phronomy::Recovery::Classification.new(
              disposition: Phronomy::Recovery::RESOLUTION_REQUIRED,
              reason: descriptor.fetch(:reason),
              subject: descriptor.fetch(:subject),
              allowed_outcomes:
                descriptor.fetch(:allowed_outcomes),
              facts: descriptor.fetch(:facts)
            )
          end

          raise Phronomy::ExecutionRehydrationRequiredError,
            "execution #{execution.execution_id} is not at an restart-safe durable continuation point " \
            "(status=#{execution.status.inspect}, phase=#{execution.phase.inspect})"
        end

        def install_on_event_loop(command)
          event_loop = Phronomy::Runtime.instance.event_loop
          plan = command.plan
          execution = plan.execution
          main = agent.send(:execution_coordinator)
          admitted = false
          bound = false
          installed = false

          event_loop.admit_agent_execution(
            agent.agent_id,
            owner_token: command.owner_token
          )
          admitted = true
          event_loop.bind_agent_execution_admission(
            agent.agent_id,
            owner_token: command.owner_token,
            execution_id: execution.execution_id
          )
          bound = true

          invocation = nil
          if execution.status == :suspended ||
              execution.phase.to_sym == :resuming
            invocation =
              RecoverySupport.build_invocation_for_suspended(
                agent,
                execution,
                plan.projection,
                main,
                agent.send(:_phronomy_event_listener)
              )
          elsif execution.phase.to_sym ==
              :recovery_tools_completed
            invocation =
              RecoverySupport.build_chat_for_recovery(
                agent,
                execution,
                plan.projection,
                main,
                agent.send(:_phronomy_event_listener)
              )
          elsif execution.phase.to_sym ==
              :recovery_provider_completed
            invocation =
              RecoverySupport.build_chat_for_recovery(
                agent,
                execution,
                plan.projection,
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
          elsif execution.phase.to_sym ==
              :recovery_resolved_failed
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
          end

          event_loop.install_agent_execution(
            execution_id: execution.execution_id,
            agent: agent,
            coordinator: main,
            execution: execution,
            runtime_projection: plan.projection,
            base_manifest: plan.base_manifest,
            invocation: invocation,
            fsm_session_id: nil
          )
          installed = true

          if execution.status == :suspended
            event_loop.mark_agent_execution_admission(
              agent.agent_id,
              execution_id: execution.execution_id,
              state: :suspended
            )
            request = invocation.approval_request
            callback_error = agent.send(
              :_deliver_stream_event,
              agent.send(:_phronomy_event_listener),
              StreamEvent.new(
                type: :approval_required,
                payload: {request: request}.freeze
              )
            )
            if callback_error
              raise agent.send(
                :_build_stream_callback_error,
                event_type: :approval_required,
                callback_error: callback_error,
                result: {
                  execution_id: execution.execution_id,
                  suspended: true
                }
              )
            end
            command.completion.complete(agent)
            return
          end

          case plan.classification.disposition
          when Phronomy::Recovery::RESOLUTION_REQUIRED
            event_loop.mark_agent_execution_admission(
              agent.agent_id,
              execution_id: execution.execution_id,
              state: :recovery_required
            )
            payload = RecoverySupport.event_payload(
              execution,
              {
                reason: plan.classification.reason,
                subject: plan.classification.subject,
                allowed_outcomes:
                  plan.classification.allowed_outcomes,
                facts: plan.classification.facts
              }
            )
            callback_error = agent.send(
              :_deliver_stream_event,
              agent.send(:_phronomy_event_listener),
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
            command.completion.complete(agent)
          when Phronomy::Recovery::RESUMABLE
            continue_resumable_on_event_loop(
              execution,
              invocation,
              completion: command.completion
            )
          else
            raise Phronomy::Error,
              "unsupported Recovery installation disposition: #{plan.classification.disposition.inspect}"
          end
        rescue => caught
          if installed
            begin
              event_loop.release_agent_execution(
              execution.execution_id
            )
            rescue
              nil
            end
          end
          if admitted
            if bound
              begin
                event_loop.release_agent_execution_admission(
                  agent.agent_id,
                  execution_id: execution&.execution_id
                )
              rescue
                nil
              end
            else
              begin
                event_loop.release_agent_execution_admission(
                  agent.agent_id,
                  owner_token: command.owner_token
                )
              rescue
                nil
              end
            end
          end
          command.completion.fail(caught)
        end

        def continue_resumable_on_event_loop(
          execution,
          invocation,
          completion:
        )
          event_loop = Phronomy::Runtime.instance.event_loop
          main = agent.send(:execution_coordinator)

          case execution.phase.to_sym
          when :resuming
            approved = execution.approval_request &&
              (
                execution.approval_request["approved"] ||
                execution.approval_request[:approved]
              )
            if approved
              raise Phronomy::ExecutionRehydrationRequiredError,
                "approved resuming execution requires Tool outcome resolution"
            end
            internal_task = Phronomy::Task.deferred(
              name: "agent-recovery-auto:#{execution.execution_id}"
            )
            event_loop.mark_agent_execution_admission(
              agent.agent_id,
              execution_id: execution.execution_id,
              state: :executing
            )
            main.send(
              :start_resume_on_event_loop,
              execution.execution_id,
              internal_task,
              approved: false,
              config: {}
            )
            completion.complete(agent)
          when :recovery_tools_completed
            internal_task = Phronomy::Task.deferred(
              name: "agent-recovery-auto:#{execution.execution_id}"
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
              internal_task
            )
            completion.complete(agent)
          when :recovery_provider_completed
            AgentInvocationSessionBuilder.send(
              :output_filtering_action,
              agent,
              invocation
            )
            internal_task = Phronomy::Task.deferred(
              name: "agent-recovery-auto:#{execution.execution_id}"
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
              internal_task
            )
            completion.complete(agent)
          when :recovery_resolved_failed
            failure = (
              execution.metadata[
                RecoverySupport::RECOVERY_METADATA_KEY
              ] || {}
            )["failure"] || {
              "class" => "Phronomy::Error",
              "message" => "Recovery-resolved failure"
            }
            error = RecoverySupport.error_from_failure(failure)
            internal_task = Phronomy::Task.deferred(
              name: "agent-recovery-auto:#{execution.execution_id}"
            )
            state = event_loop.agent_execution_state(
              execution.execution_id
            )
            main.send(
              :begin_terminal_commit_on_event_loop,
              state,
              internal_task,
              invocation,
              error,
              fsm_session_id: nil
            )
            completion.complete(agent)
          else
            raise Phronomy::ExecutionRehydrationRequiredError,
              "no automatic continuation for #{execution.phase.inspect}"
          end
        end
      end
    end
  end
end
