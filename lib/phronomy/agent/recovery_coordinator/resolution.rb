# frozen_string_literal: true

module Phronomy
  module Agent
    class RecoveryCoordinator
      # Resolution portion of durable Agent Recovery.
      # @api private
      module Resolution
        private

        def begin_resolve_on_event_loop(request)
          event_loop = Phronomy::Runtime.instance.event_loop
          state = event_loop.agent_execution_state(
            request.execution_id
          )
          unless state && state.agent.equal?(agent)
            request.completion.fail(
              Phronomy::ExecutionRehydrationRequiredError.new(
                "no live recovered execution #{request.execution_id}"
              )
            )
            return
          end

          current = state.execution
          unless current.execution_revision ==
              request.expected_execution_revision
            request.completion.fail(
              Phronomy::Persistence::ConflictError.new(
                "Recovery resolution revision conflict: expected " \
                "#{request.expected_execution_revision}, actual " \
                "#{current.execution_revision}"
              )
            )
            return
          end

          descriptor =
            RecoverySupport.recovery_descriptor(current)
          unless descriptor &&
              Phronomy::Recovery.subject_equal?(
                descriptor.fetch(:subject),
                request.subject
              )
            request.completion.fail(
              ArgumentError.new(
                "Recovery subject is not current for execution #{request.execution_id}"
              )
            )
            return
          end

          unless Array(
            descriptor.fetch(:allowed_outcomes)
          ).map(&:to_sym).include?(request.outcome)
            request.completion.fail(
              ArgumentError.new(
                "Recovery outcome #{request.outcome.inspect} is not allowed for the current subject"
              )
            )
            return
          end

          operation = ResolutionOperation.new(
            execution: current,
            root: agent.agent_root,
            subject: request.subject,
            outcome: request.outcome,
            result: request.result,
            failure: request.failure
          )
          event_loop.mark_agent_execution_admission(
            agent.agent_id,
            execution_id: current.execution_id,
            state: :recovery_required
          )
          task = Phronomy::Runtime.instance.offload.submit(
            on_full: :raise
          ) do
            perform_resolution(operation)
          end
          task.on_complete do |result, error|
            ready = ResolveReady.new(
              coordinator: self,
              request: request,
              operation: operation,
              result: result,
              error: error
            )
            unless post_control(ready)
              request.completion.fail(
                Phronomy::RuntimeShutdownError.new(
                  "EventLoop rejected Recovery resolution apply"
                )
              )
            end
          end
        rescue => caught
          request.completion.fail(caught)
        end

        def perform_resolution(operation)
          case operation.subject.fetch(:type)
          when :llm_call
            resolve_llm(operation)
          when :tool_invocation
            resolve_tool(operation)
          else
            raise ArgumentError,
              "unsupported Recovery subject: #{operation.subject.inspect}"
          end
        end

        def resolve_llm(operation)
          current = operation.execution
          llm_call_id =
            operation.subject.fetch(:llm_call_id).to_s
          unless current.metadata[
            RecoverySupport::PENDING_LLM_ID_KEY
          ].to_s == llm_call_id
            raise Phronomy::Persistence::ConflictError,
              "LLM Recovery subject is no longer pending"
          end

          case operation.outcome
          when :not_performed
            # The factual ambiguity is resolved, but Recovery deliberately does not
            # invent a generic semantic-retry contract. Without an operation-
            # specific replay contract, fail the logical execution explicitly
            # rather than asking the Application to provide a second, non-factual
            # "resolution" or blindly redispatching the Provider call.
            failure = {
              "class" => "Phronomy::Error",
              "message" =>
                "Recovery confirmed LLM call #{llm_call_id} was not performed; " \
                "automatic semantic redispatch is unavailable without a replay contract"
            }.freeze
            recovery = {
              "version" => RecoverySupport::CONTRACT_VERSION,
              "resolution_outcome" => "not_performed",
              "failure" => failure
            }.freeze
            updated = current.with(
              phase: :recovery_resolved_failed,
              metadata: current.metadata.merge(
                RecoverySupport::RECOVERY_METADATA_KEY => recovery
              )
            )
            intended = ResolutionResult.new(
              execution: updated,
              root: operation.root,
              continuation: :failed_terminal,
              failure: failure,
              appended_records: [].freeze
            )
            save_resolution_result(current, intended)
          when :failed
            recovery = {
              "version" => RecoverySupport::CONTRACT_VERSION,
              "failure" => operation.failure
            }
            updated = current.with(
              phase: :recovery_resolved_failed,
              metadata: current.metadata.merge(
                RecoverySupport::RECOVERY_METADATA_KEY =>
                  recovery
              )
            )
            intended = ResolutionResult.new(
              execution: updated,
              root: operation.root,
              continuation: :failed_terminal,
              failure: operation.failure,
              appended_records: [].freeze
            )
            save_resolution_result(current, intended)
          when :succeeded
            # simplecov:disable
            outcome =
              Phronomy::Agent::ProviderCallOutcome.from_h(
                operation.result
              )
            updated = nil
            with_resolution_f1_capture do |tx|
              main = agent.send(:execution_coordinator)
              snapshot = {
                llm_results: [{
                  llm_call_id: llm_call_id,
                  response: outcome,
                  error: nil,
                  streaming: (
                    current.metadata[
                      RecoverySupport::INVOCATION_MODE_KEY
                    ].to_s == "stream"
                  ),
                  manifest_ref: current.metadata.fetch(
                    "manifest_ref"
                  ),
                  started_at: current.metadata[
                    RecoverySupport::PENDING_LLM_STARTED_AT_KEY
                  ] || current.updated_at
                }.freeze].freeze,
                runtime_events: [].freeze,
                active_call: nil
              }.freeze
              records, calls = main.send(
                :encode_runtime_records,
                current,
                tx: tx,
                snapshot: snapshot,
                context_candidate: true,
                agent_root: operation.root
              )
              subjects =
                RecoverySupport.build_tool_subjects(
                  current,
                  llm_call_id,
                  outcome
                )
              next_phase = subjects.empty? ?
                :recovery_provider_completed : :recovery_tools
              metadata = current.metadata.dup
              metadata.delete(
                RecoverySupport::PENDING_LLM_ID_KEY
              )
              metadata.delete(
                RecoverySupport::PENDING_LLM_STARTED_AT_KEY
              )
              if subjects.empty?
                metadata.delete(
                  RecoverySupport::RECOVERY_METADATA_KEY
                )
              else
                metadata[
                  RecoverySupport::RECOVERY_METADATA_KEY
                ] = RecoverySupport.build_recovery_hash(
                  subjects
                )
              end
              updated = current.with(
                phase: next_phase,
                working_records:
                  current.working_records + records,
                llm_calls: current.llm_calls + calls,
                metadata: metadata
              )
              tx.executions.save(
                current.execution_id,
                expected_revision: current.execution_revision,
                execution: updated
              )
              ResolutionResult.new(
                execution: updated,
                root: operation.root,
                continuation: (
                  (updated.phase.to_sym ==
                    :recovery_provider_completed) ?
                      :provider_completed :
                      :resolution_required
                ),
                failure: nil,
                appended_records: [].freeze
              )
            end
            # simplecov:enable
          end
        end

        def resolve_tool(operation)
          # simplecov:disable
          current = operation.execution
          recovery = RecoverySupport.recovery_hash(current)
          if recovery.nil? && current.phase.to_sym == :resuming
            subjects = RecoverySupport.resuming_tool_subjects(current)
            recovery = RecoverySupport.build_recovery_hash(subjects)
          end
          unless recovery
            raise Phronomy::Persistence::ConflictError,
              "Tool Recovery state is missing"
          end

          subject_entry = Array(
            recovery["subjects"] || recovery[:subjects]
          ).find do |entry|
            hash = entry.to_h { |key, value| [key.to_s, value] }
            hash.fetch("tool_invocation_id").to_s ==
              operation.subject.fetch(:tool_invocation_id).to_s &&
              hash.fetch("state", "unresolved") == "unresolved"
          end
          unless subject_entry
            raise Phronomy::Persistence::ConflictError,
              "Tool Recovery subject is no longer unresolved"
          end
          subject_entry =
            subject_entry.to_h { |key, value| [key.to_s, value] }

          case operation.outcome
          when :not_performed
            tool_id = subject_entry.fetch("tool_invocation_id").to_s
            failure = {
              "class" => "Phronomy::Error",
              "message" =>
                "Recovery confirmed Tool invocation #{tool_id} was not performed; " \
                "automatic semantic redispatch is unavailable without a replay contract"
            }.freeze
            resolved_recovery =
              RecoverySupport.update_recovery_subject(
                recovery,
                tool_invocation_id: tool_id,
                state: :resolved,
                outcome: :not_performed
              ).merge(
                "resolution_outcome" => "not_performed",
                "failure" => failure
              ).freeze
            updated = current.with(
              phase: :recovery_resolved_failed,
              metadata: current.metadata.merge(
                RecoverySupport::RECOVERY_METADATA_KEY =>
                  resolved_recovery
              )
            )
            intended = ResolutionResult.new(
              execution: updated,
              root: operation.root,
              continuation: :failed_terminal,
              failure: failure,
              appended_records: [].freeze
            )
            save_resolution_result(current, intended)
          when :failed
            recovery_with_failure =
              RecoverySupport.update_recovery_subject(
                recovery,
                tool_invocation_id:
                  subject_entry.fetch("tool_invocation_id"),
                state: :resolved,
                outcome: :failed
              ).merge(
                "failure" => operation.failure
              )
            updated = current.with(
              phase: :recovery_resolved_failed,
              metadata: current.metadata.merge(
                RecoverySupport::RECOVERY_METADATA_KEY =>
                  recovery_with_failure
              )
            )
            intended = ResolutionResult.new(
              execution: updated,
              root: operation.root,
              continuation: :failed_terminal,
              failure: operation.failure,
              appended_records: [].freeze
            )
            save_resolution_result(current, intended)
          when :succeeded
            updated = nil
            with_resolution_f1_capture do |tx|
              main = agent.send(:execution_coordinator)
              result_ref = main.send(
                :put_runtime_content,
                tx,
                operation.result
              )
              message = {
                "role" => "tool",
                "content" => operation.result.to_s,
                "tool_call_id" =>
                  subject_entry.fetch("tool_call_id").to_s
              }
              runtime_event = StreamEvent.new(
                type: :tool_result,
                payload: {
                  tool_call_id:
                    subject_entry.fetch("tool_call_id").to_s,
                  tool_name:
                    subject_entry.fetch("tool_name").to_s,
                  tool_result: operation.result,
                  tool_message: message,
                  llm_call_id:
                    subject_entry.fetch("llm_call_id").to_s
                }.freeze
              )
              records, _calls = main.send(
                :encode_runtime_records,
                current,
                tx: tx,
                snapshot: {
                  llm_results: [].freeze,
                  runtime_events: [runtime_event].freeze,
                  active_call: nil
                }.freeze,
                context_candidate: true,
                agent_root: operation.root
              )
              next_recovery =
                RecoverySupport.update_recovery_subject(
                  recovery,
                  tool_invocation_id:
                    subject_entry.fetch("tool_invocation_id"),
                  state: :resolved,
                  outcome: :succeeded,
                  result_ref: result_ref
                )
              unresolved =
                RecoverySupport.unresolved_subjects(
                  next_recovery
                )
              next_phase = unresolved.empty? ?
                :recovery_tools_completed : :recovery_tools
              updated = current.with(
                phase: next_phase,
                working_records:
                  current.working_records + records,
                metadata: current.metadata.merge(
                  RecoverySupport::RECOVERY_METADATA_KEY =>
                    next_recovery
                )
              )
              tx.executions.save(
                current.execution_id,
                expected_revision: current.execution_revision,
                execution: updated
              )
              ResolutionResult.new(
                execution: updated,
                root: operation.root,
                continuation: (
                  (updated.phase.to_sym ==
                    :recovery_tools_completed) ?
                      :tools_completed :
                      :resolution_required
                ),
                failure: nil,
                appended_records: [].freeze
              )
            end
          end
        end
        # simplecov:enable

        def known_non_f1_error?(error)
          error.is_a?(Phronomy::Persistence::ConflictError) ||
            error.is_a?(Phronomy::Persistence::NotFoundError) ||
            error.is_a?(Phronomy::Persistence::SerializationError) ||
            error.is_a?(Phronomy::Persistence::UnsupportedBackendError) ||
            error.is_a?(ArgumentError) ||
            error.is_a?(Phronomy::ConfigurationError)
        end

        def with_resolution_f1_capture
          intended = nil
          begin
            agent.persistence.transaction do |tx|
              intended = yield(tx)
              intended
            end
            intended
          rescue => caught
            raise if known_non_f1_error?(caught)
            raise unless intended

            raise ResolutionOutcomeUnknownError.new(
              caught,
              intended
            )
          end
        end

        def save_resolution_result(current, result)
          with_resolution_f1_capture do |tx|
            tx.executions.save(
              current.execution_id,
              expected_revision: current.execution_revision,
              execution: result.execution
            )
            result
          end
        end

        def apply_resolve_on_event_loop(ready)
          request = ready.request
          event_loop = Phronomy::Runtime.instance.event_loop
          state = event_loop.agent_execution_state(
            request.execution_id
          )
          unless state && state.agent.equal?(agent)
            request.completion.fail(
              Phronomy::ExecutionRehydrationRequiredError.new(
                "recovered execution disappeared before resolution apply"
              )
            )
            return
          end

          if ready.error
            reconcile_resolution_f1_on_event_loop(
              ready,
              state
            )
            return
          end

          result = ready.result
          event_loop.replace_agent_execution(
            request.execution_id,
            execution: result.execution
          )

          case result.continuation
          when :resolution_required
            event_loop.mark_agent_execution_admission(
              agent.agent_id,
              execution_id: request.execution_id,
              state: :recovery_required
            )
            descriptor =
              RecoverySupport.recovery_descriptor(
                result.execution
              )
            deliver_resolution_required(
              result.execution,
              descriptor
            )
            request.completion.complete(
              {
                execution_id: request.execution_id,
                execution_revision:
                  result.execution.execution_revision,
                recovery: :resolution_required
              }.freeze
            )
          when :provider_completed
            continue_provider_completed_after_resolution(
              event_loop,
              state,
              result.execution,
              request.completion
            )
          when :tools_completed
            continue_tools_completed_after_resolution(
              event_loop,
              state,
              result.execution,
              request.completion
            )
          when :failed_terminal
            continue_failed_after_resolution(
              event_loop,
              state,
              result.execution,
              request.completion,
              result.failure
            )
          else
            request.completion.fail(
              Phronomy::Error.new(
                "unknown Recovery continuation: #{result.continuation.inspect}"
              )
            )
          end
        rescue => caught
          request.completion.fail(caught)
        end

        def reconcile_resolution_f1_on_event_loop(ready, state)
          request = ready.request
          intended_result = ready.result
          if intended_result.nil? &&
              ready.error.is_a?(ResolutionOutcomeUnknownError)
            intended_result = ready.error.intended_result
          end
          intended = intended_result&.execution
          current = agent.persistence.executions.load(
            request.execution_id
          )

          if intended &&
              current.execution_revision ==
                  intended.execution_revision &&
              current.to_h == intended.to_h
            Phronomy::Runtime.instance.event_loop.replace_agent_execution(
              request.execution_id,
              execution: current
            )
            synthetic = ResolveReady.new(
              coordinator: self,
              request: request,
              operation: ready.operation,
              result: intended_result.class.new(
                execution: current,
                root: intended_result.root,
                continuation: intended_result.continuation,
                failure: intended_result.failure,
                appended_records:
                  intended_result.appended_records
              ),
              error: nil
            )
            apply_resolve_on_event_loop(synthetic)
            return
          end

          if current.execution_revision ==
              ready.operation.execution.execution_revision &&
              current.to_h ==
                  ready.operation.execution.to_h
            failure = if ready.error.is_a?(
              ResolutionOutcomeUnknownError
            )
              ready.error.original_error
            else
              ready.error
            end
            request.completion.fail(failure)
            return
          end

          request.completion.fail(
            Phronomy::Persistence::ConflictError.new(
              "Recovery resolution durable outcome conflicts with both expected pre-state and intended post-state"
            )
          )
        rescue => reconciliation_error
          request.completion.fail(reconciliation_error)
        end
      end
    end
  end
end
