# frozen_string_literal: true

require "time"

module Phronomy
  module Agent
    class ExecutionCoordinator
      # External/API -> EventLoop control messages.
      StartCommand = Data.define(
        :coordinator, :input, :config, :mode,
        :approval_policy, :approval_listener, :on_event, :result_task,
        :admission_token
      )
      ResumeCommand = Data.define(
        :coordinator, :execution_id, :approval_request_id,
        :approved, :config, :result_task
      )

      # EventLoop -> Offload operation-specific immutable snapshots.
      InitialPreparationCommand = Data.define(
        :root, :journal_records, :input, :config
      )
      FollowupPreparationCommand = Data.define(
        :execution_id, :fsm_session_id, :expected_execution_revision,
        :root, :journal_records, :execution, :base_manifest,
        :invocation_config, :runtime_snapshot, :streaming
      )
      ResumeCommitCommand = Data.define(
        :execution_id, :expected_execution_revision,
        :root, :execution, :approval_request_id, :approved
      )
      HandoffTerminalView = Data.define(
        :target_agent_id, :responsibility, :selection_intent,
        :llm_call_id, :tool_call_id
      )
      TerminalView = Data.define(
        :phase, :output, :usage, :approval_request, :rejected,
        :input_blocked, :output_blocked, :block_error,
        :invocation_error, :handoff, :callback_failure, :source_error
      )
      TerminalCommitCommand = Data.define(
        :execution_id, :fsm_session_id, :expected_execution_revision,
        :root, :journal_records, :execution, :runtime_snapshot,
        :terminal_view, :state_required
      )
      TerminalDelivery = Data.define(
        :result_task, :application_listener, :approval_listener,
        :handoff_request, :handoff_manifest
      )

      # Offload -> EventLoop operation results. No live Agent/Invocation object is
      # mutated by a worker; these values are validated and applied on EventLoop.
      InitialPreparationResult = Data.define(
        :execution, :root, :runtime_projection, :filtered_input,
        :config, :appended_records, :error, :admission_outcome
      )
      FollowupPreparationResult = Data.define(:execution, :runtime_projection, :error)
      ResumeCommitResult = Data.define(:execution, :root)
      TerminalOutcome = Data.define(
        :type, :execution, :root, :appended_records,
        :result, :error, :approval_request
      )

      InitialPreparationReady = Data.define(
        :coordinator, :request, :result, :error
      )
      FollowupPreparationReady = Data.define(
        :coordinator, :operation, :result, :error
      )
      ResumeCommitReady = Data.define(
        :coordinator, :request, :operation, :result, :error
      )
      TerminalCommitReady = Data.define(
        :coordinator, :operation, :delivery, :outcome, :error
      )

      def initialize(agent)
        @agent = agent
      end

      def start(
        input, config: {}, mode: :invoke,
        approval_policy: nil, approval_listener: nil, on_event: nil
      )
        @agent.send(:__assert_live_agent!)
        @agent.send(:_reject_removed_generic_identity_keys!, config)
        result_task = Phronomy::Task.deferred(name: "agent-#{@agent.agent_id}-#{mode}")
        command = StartCommand.new(
          coordinator: self,
          input: input,
          config: config.dup.freeze,
          mode: mode.to_sym,
          approval_policy: approval_policy,
          approval_listener: approval_listener,
          on_event: on_event,
          result_task: result_task,
          admission_token: Object.new.freeze
        )
        unless post_control(Phronomy::Runtime.instance, command)
          fail_task(result_task, runtime_rejected_error(:start))
        end
        result_task
      rescue => error
        fail_task(result_task, translated(error)) if defined?(result_task) && result_task
        result_task
      end

      def resume(
        execution_id,
        approval_request_id:,
        approved:,
        config: {}
      )
        @agent.send(:__assert_live_agent!)
        @agent.send(:_reject_removed_generic_identity_keys!, config)
        result_task = Phronomy::Task.deferred(
          name: "agent-approval-resume:#{execution_id}"
        )
        command = ResumeCommand.new(
          coordinator: self,
          execution_id: execution_id.to_s.freeze,
          approval_request_id: approval_request_id.to_s.freeze,
          approved: !!approved,
          config: config.dup.freeze,
          result_task: result_task
        )
        unless post_control(Phronomy::Runtime.instance, command)
          fail_task(result_task, runtime_rejected_error(:resume))
        end
        result_task
      rescue => error
        fail_task(result_task, translated(error)) if defined?(result_task) && result_task
        result_task
      end

      # Called only from the Agent FSMSession's :calling_llm entry action on
      # EventLoop. Captures the current immutable durable/runtime facts and sends
      # exactly that operation snapshot to OffloadPool.
      # @api private
      def prepare_next_llm_call(invocation, event_sink:, streaming:)
        runtime = Phronomy::Runtime.instance
        event_loop = runtime.event_loop
        assert_event_loop!(event_loop)
        state = event_loop.agent_execution_state(invocation.execution_id)
        validate_live_session!(state, invocation, event_sink.fsm_session_id)
        unless event_loop.fsm_session_state(event_sink.fsm_session_id) == :calling_llm
          raise Phronomy::Error,
            "follow-up LLM preparation requires the owning FSMSession to be in :calling_llm"
        end

        operation = FollowupPreparationCommand.new(
          execution_id: state.execution_id,
          fsm_session_id: event_sink.fsm_session_id.to_s.freeze,
          expected_execution_revision: state.execution.execution_revision,
          root: @agent.agent_root,
          journal_records: @agent.send(:_journal_records_snapshot),
          execution: state.execution,
          base_manifest: state.base_manifest,
          invocation_config: invocation.config.dup.freeze,
          runtime_snapshot: invocation.runtime_snapshot,
          streaming: !!streaming
        )
        task = runtime.offload.submit(on_full: :raise) do
          perform_followup_preparation(operation)
        end
        task.on_complete do |result, error|
          ready = FollowupPreparationReady.new(
            coordinator: self,
            operation: operation,
            result: result,
            error: error
          )
          unless post_control(runtime, ready)
            # The durable operation may already have committed. Do not mutate live
            # state from this callback thread merely to emulate EventLoop apply.
            Phronomy.configuration.logger&.warn(
              "[Phronomy] EventLoop rejected follow-up durable result for " \
              "#{operation.execution_id}"
            )
          end
        end
        nil
      rescue => error
        event_sink.post(:llm_setup_failed, translated(error))
        nil
      end

      # Every control message is delivered by EventLoop. This method is the only
      # coordinator entry point allowed to advance Phronomy-managed live state.
      # @api private
      def deliver_on_event_loop(command)
        event_loop = Phronomy::Runtime.instance.event_loop
        assert_event_loop!(event_loop)

        case command
        when StartCommand
          begin_start_on_event_loop(command)
        when InitialPreparationReady
          apply_initial_preparation_on_event_loop(command)
        when FollowupPreparationReady
          apply_followup_preparation_on_event_loop(command)
        when ResumeCommand
          begin_resume_on_event_loop(command)
        when ResumeCommitReady
          apply_resume_commit_on_event_loop(command)
        when TerminalCommitReady
          apply_terminal_commit_on_event_loop(command)
        else
          raise Phronomy::Error, "unknown Agent control command: #{command.class}"
        end
      end

      private

      # ----------------------------------------------------------------------
      # Initial preparation
      # ----------------------------------------------------------------------

      def begin_start_on_event_loop(request)
        runtime = Phronomy::Runtime.instance
        event_loop = runtime.event_loop
        root = @agent.agent_root
        if root.lifecycle_status == :closed
          deliver_start_failure_on_event_loop(
            request,
            Phronomy::Error.new("agent is closed: #{@agent.agent_id}")
          )
          return
        end

        @agent.send(:__assert_live_agent!)
        admitted = false
        submitted = false
        event_loop.admit_agent_execution(
          @agent.agent_id,
          owner_token: request.admission_token
        )
        admitted = true

        # Ownership purge may begin on an application thread between the first
        # live-owner check and EventLoop admission. Re-check after the slot is
        # installed: once this check succeeds, purge observes the admission and
        # must abort instead of deleting the Agent underneath this start.
        @agent.send(:__assert_live_agent!)

        operation = InitialPreparationCommand.new(
          root: root,
          journal_records: @agent.send(:_journal_records_snapshot),
          input: request.input,
          config: request.config
        )
        task = runtime.offload.submit(on_full: :raise) do
          perform_initial_preparation(operation)
        end
        submitted = true
        task.on_complete do |result, error|
          ready = InitialPreparationReady.new(
            coordinator: self,
            request: request,
            result: result,
            error: error
          )
          fail_task(request.result_task, runtime_rejected_error(:initial_preparation)) unless
            post_control(runtime, ready)
        end
      rescue => error
        if admitted
          if submitted
            event_loop.mark_agent_admission_recovery_required(
              @agent.agent_id,
              owner_token: request.admission_token
            )
          else
            event_loop.release_agent_execution_admission(
              @agent.agent_id,
              owner_token: request.admission_token
            )
          end
        end
        deliver_start_failure_on_event_loop(request, translated(error))
      end

      def perform_initial_preparation(operation)
        begin
          raw_message = @agent.send(:extract_message, operation.input)
        rescue => error
          return InitialPreparationResult.new(
            execution: nil,
            root: operation.root,
            runtime_projection: nil,
            filtered_input: nil,
            config: operation.config,
            appended_records: [].freeze,
            error: translated(error),
            admission_outcome: :not_established
          )
        end

        begin
          execution, active_root = admit_execution(raw_message, root: operation.root)
        rescue Phronomy::AgentBusyError => error
          # A durable busy conflict proves that another nonterminal logical
          # Execution already exists for this agent_id. Process loss does not
          # make that execution terminal; keep Runtime admission fail-closed
          # until ACS-15 recovery/reconciliation can establish current lineage.
          return InitialPreparationResult.new(
            execution: nil,
            root: operation.root,
            runtime_projection: nil,
            filtered_input: nil,
            config: operation.config,
            appended_records: [].freeze,
            error: translated(error),
            admission_outcome: :recovery_required
          )
        rescue Phronomy::Persistence::ConflictError,
          Phronomy::Persistence::NotFoundError,
          Phronomy::Persistence::SerializationError,
          ArgumentError,
          Phronomy::ConfigurationError => error
          return InitialPreparationResult.new(
            execution: nil,
            root: operation.root,
            runtime_projection: nil,
            filtered_input: nil,
            config: operation.config,
            appended_records: [].freeze,
            error: translated(error),
            admission_outcome: :not_established
          )
        rescue => error
          return InitialPreparationResult.new(
            execution: nil,
            root: operation.root,
            runtime_projection: nil,
            filtered_input: nil,
            config: operation.config,
            appended_records: [].freeze,
            error: translated(error),
            admission_outcome: :outcome_unknown
          )
        end

        current_execution = execution
        begin
          effective_config = operation.config
          @agent.send(
            :check_cancellation!,
            effective_config,
            "invocation cancelled before input filtering"
          )
          filtered_input = @agent.send(:run_input_filters!, operation.input)
          @agent.send(
            :check_cancellation!,
            effective_config,
            "invocation cancelled before context assembly"
          )
          filtered_message = @agent.send(:extract_message, filtered_input)
          manifest = manifest_ref = active_execution = nil

          @agent.persistence.transaction do |tx|
            assert_local_durable_base!(tx, active_root)
            filtered_ref = tx.contents.put_text(filtered_message)
            input_record = JournalRecord.new(
              agent_id: @agent.agent_id,
              execution_id: current_execution.execution_id,
              kind: :external_message,
              channel: :external,
              role: :user,
              content_ref: filtered_ref,
              context_generation: active_root.transcript_generation,
              context_candidate: true
            )
            staged = current_execution.with(
              execution_revision: current_execution.execution_revision,
              working_records: current_execution.working_records + [input_record],
              metadata: current_execution.metadata.merge(
                "current_input_ref" => filtered_ref,
                "current_input_record_id" => input_record.record_id
              )
            )
            manifest, manifest_ref = ContextAssembler.new(
              agent: @agent,
              persistence: tx,
              policy: context_policy_for(staged),
              journal_records: operation.journal_records
            ).build_initial(
              input: filtered_input,
              agent_root: active_root,
              execution: staged,
              config: effective_config,
              patch: @agent.send(
                :run_before_llm_input_hooks,
                call_sequence: 1,
                config: effective_config
              )
            )
            active_execution = staged.with(
              status: :active,
              phase: :calling_llm,
              metadata: staged.metadata.merge(
                "base_manifest_ref" => manifest_ref,
                "manifest_ref" => manifest_ref,
                "manifest_refs" => [manifest_ref]
              )
            )
            tx.executions.save(
              current_execution.execution_id,
              expected_revision: current_execution.execution_revision,
              execution: active_execution
            )
          end
          current_execution = active_execution

          projection = RubyLLMMaterializer.new(
            agent: @agent,
            persistence: @agent.persistence
          ).materialize(manifest: manifest, manifest_ref: manifest_ref)
          InitialPreparationResult.new(
            execution: active_execution,
            root: active_root,
            runtime_projection: projection,
            filtered_input: filtered_input,
            config: effective_config,
            appended_records: [].freeze,
            error: nil,
            admission_outcome: :active
          )
        rescue => error
          failure = commit_preparation_failure(
            current_execution,
            active_root,
            error
          )
          InitialPreparationResult.new(
            execution: failure.fetch(:execution),
            root: failure.fetch(:root),
            runtime_projection: nil,
            filtered_input: nil,
            config: operation.config,
            appended_records: failure.fetch(:appended_records),
            error: failure.fetch(:error),
            admission_outcome: :terminal
          )
        end
      end

      def admit_execution(raw_message, root:)
        raise Phronomy::Error, "agent is closed: #{@agent.agent_id}" if root.lifecycle_status == :closed

        execution = next_root = nil
        @agent.persistence.transaction do |tx|
          input_ref = tx.contents.put_text(raw_message)
          input_record = JournalRecord.new(
            agent_id: @agent.agent_id,
            kind: :input_received,
            channel: :external,
            role: :user,
            content_ref: input_ref,
            context_generation: root.transcript_generation,
            context_candidate: false
          )
          policy_descriptor = ContextPolicies::Default.new.descriptor
          execution = AgentExecution.start(
            agent_root: root,
            input_record: input_record,
            metadata: {
              "current_input_ref" => input_ref,
              "context_policy" => policy_descriptor.to_h
            }.compact
          )
          input_record = JournalRecord.from_h(
            input_record.to_h.merge("execution_id" => execution.execution_id)
          )
          execution = execution.with(
            execution_revision: 0,
            working_records: [input_record]
          )
          tx.executions.create_active(execution)
          next_root = root.with(
            agent_revision: root.agent_revision + 1,
            lifecycle_status: :active
          )
          tx.agents.save(
            root.agent_id,
            expected_revision: root.agent_revision,
            root: next_root
          )
        end
        [execution, next_root]
      end

      def commit_preparation_failure(execution, root, error)
        translated_error = translated(error)
        failed = next_root = appended = nil

        @agent.persistence.transaction do |tx|
          error_ref = tx.contents.put_json(
            "class" => translated_error.class.name,
            "message" => translated_error.message
          )
          audit_records = execution.working_records.map do |record|
            JournalRecord.from_h(
              record.to_h.merge("context_candidate" => false)
            )
          end
          terminal_status = terminal_status_for(translated_error)
          audit_records << JournalRecord.new(
            agent_id: @agent.agent_id,
            execution_id: execution.execution_id,
            kind: execution_terminal_kind(terminal_status),
            channel: :audit,
            content_ref: error_ref,
            context_generation: root.transcript_generation,
            context_candidate: false
          )
          appended = tx.journals.append(
            root.agent_id,
            expected_position: root.journal_position,
            records: audit_records
          )
          failed = execution.with(
            status: terminal_status,
            phase: terminal_status,
            working_records: [],
            error_ref: error_ref,
            terminal_reason: translated_error.class.name
          )
          tx.executions.save(
            execution.execution_id,
            expected_revision: execution.execution_revision,
            execution: failed
          )
          next_root = root.with(
            agent_revision: root.agent_revision + 1,
            journal_position: root.journal_position + appended.length,
            lifecycle_status: :idle
          )
          tx.agents.save(
            root.agent_id,
            expected_revision: root.agent_revision,
            root: next_root
          )
        end
        {
          error: translated_error,
          execution: failed,
          root: next_root,
          appended_records: Array(appended).freeze
        }.freeze
      end

      def apply_initial_preparation_on_event_loop(ready)
        request = ready.request
        event_loop = Phronomy::Runtime.instance.event_loop
        if ready.error
          event_loop.mark_agent_admission_recovery_required(
            @agent.agent_id,
            owner_token: request.admission_token
          )
          deliver_start_failure_on_event_loop(request, translated(ready.error))
          return
        end

        result = ready.result
        case result.admission_outcome
        when :not_established
          event_loop.release_agent_execution_admission(
            @agent.agent_id,
            owner_token: request.admission_token
          )
          deliver_start_failure_on_event_loop(request, result.error)
          return
        when :outcome_unknown, :recovery_required
          event_loop.mark_agent_admission_recovery_required(
            @agent.agent_id,
            owner_token: request.admission_token
          )
          deliver_start_failure_on_event_loop(request, result.error)
          return
        when :active, :terminal
          event_loop.bind_agent_execution_admission(
            @agent.agent_id,
            owner_token: request.admission_token,
            execution_id: result.execution.execution_id
          )
        else
          event_loop.mark_agent_admission_recovery_required(
            @agent.agent_id,
            owner_token: request.admission_token
          )
          raise Phronomy::Error,
            "unknown initial admission outcome: #{result.admission_outcome.inspect}"
        end

        apply_agent_live_state(
          root: result.root,
          appended_records: result.appended_records
        )
        if result.admission_outcome == :terminal
          event_loop.release_agent_execution_admission(
            @agent.agent_id,
            execution_id: result.execution.execution_id
          )
          deliver_start_failure_on_event_loop(request, result.error)
          return
        end

        register_initial_session_on_event_loop(request, result)
      rescue => error
        # Preparation may already be durably active. Terminalize through another
        # offloaded durable operation rather than releasing the admission blindly.
        begin_terminal_without_session_on_event_loop(
          request: request,
          prepared: ready.result,
          error: error
        )
      end

      def register_initial_session_on_event_loop(request, prepared)
        runtime = Phronomy::Runtime.instance
        event_loop = runtime.event_loop
        effective_config = prepared.config.merge(
          phronomy_execution_coordinator: self,
          phronomy_runtime_projection: prepared.runtime_projection,
          phronomy_filtered_input: prepared.filtered_input,
          execution_id: prepared.execution.execution_id
        )
        session = Agent::AgentInvocationSessionBuilder.build(
          agent: @agent,
          input: prepared.filtered_input,
          config: effective_config,
          approval_policy: request.approval_policy,
          approval_listener: request.approval_listener,
          mode: request.mode,
          on_event: request.on_event,
          runtime: runtime
        )
        event_loop.install_agent_execution(
          execution_id: prepared.execution.execution_id,
          agent: @agent,
          coordinator: self,
          execution: prepared.execution,
          runtime_projection: prepared.runtime_projection,
          base_manifest: prepared.runtime_projection.manifest,
          invocation: session.context,
          fsm_session_id: session.id
        )
        source_task = Phronomy::Task.deferred(name: "#{request.result_task.name}-source")
        source_task.on_complete do |invocation, error|
          finish_on_event_loop(
            prepared.execution.execution_id,
            request.result_task,
            invocation || session.context,
            error,
            fsm_session_id: session.id
          )
        end
        event_loop.register(session, completion: source_task)
      rescue => _error
        event_loop&.release_agent_execution(prepared.execution.execution_id) if
          event_loop&.current? && event_loop.agent_execution_state(prepared.execution.execution_id)
        raise
      end

      def deliver_start_failure_on_event_loop(request, error)
        callback_error = @agent.send(
          :_deliver_stream_event,
          request.on_event,
          StreamEvent.new(
            type: terminal_event_type(error),
            payload: {error: error}
          )
        )
        settle_after_terminal(
          request.result_task,
          callback_error,
          terminal_event_type(error),
          nil,
          error
        )
      end

      # ----------------------------------------------------------------------
      # Follow-up durable barrier
      # ----------------------------------------------------------------------

      def perform_followup_preparation(operation)
        manifest = manifest_ref = updated = nil

        @agent.persistence.transaction do |tx|
          assert_local_durable_base!(tx, operation.root)
          encoded_records, call_records = encode_runtime_records(
            operation.execution,
            tx: tx,
            snapshot: operation.runtime_snapshot,
            context_candidate: true,
            agent_root: operation.root
          )
          staged = operation.execution.with(
            execution_revision: operation.execution.execution_revision,
            phase: :preparing_llm_call,
            working_records: operation.execution.working_records + encoded_records,
            llm_calls: operation.execution.llm_calls + call_records
          )
          patch = @agent.send(
            :run_before_llm_input_hooks,
            call_sequence: staged.llm_calls.length + 1,
            config: operation.invocation_config
          )
          manifest, manifest_ref = ContextAssembler.new(
            agent: @agent,
            persistence: tx,
            policy: context_policy_for(staged),
            journal_records: operation.journal_records
          ).build_followup(
            base_manifest: operation.base_manifest,
            agent_root: operation.root,
            execution: staged,
            config: operation.invocation_config,
            patch: patch
          )
          refs = Array(staged.metadata["manifest_refs"]) + [manifest_ref]
          updated = staged.with(
            phase: :calling_llm,
            metadata: staged.metadata.merge(
              "manifest_ref" => manifest_ref,
              "manifest_refs" => refs
            )
          )
          tx.executions.save(
            operation.execution.execution_id,
            expected_revision: operation.execution.execution_revision,
            execution: updated
          )
        end

        projection = materialization_error = nil
        begin
          projection = RubyLLMMaterializer.new(
            agent: @agent,
            persistence: @agent.persistence
          ).materialize(manifest: manifest, manifest_ref: manifest_ref)
        rescue => error
          # The execution save above has already committed. Return that known
          # committed execution to EventLoop even when runtime materialization
          # fails, so live revision/snapshot authority cannot remain stale.
          materialization_error = error
        end
        FollowupPreparationResult.new(
          execution: updated,
          runtime_projection: projection,
          error: materialization_error
        )
      end

      def apply_followup_preparation_on_event_loop(ready)
        operation = ready.operation
        event_loop = Phronomy::Runtime.instance.event_loop
        state = authoritative_state_for_operation(
          execution_id: operation.execution_id,
          fsm_session_id: operation.fsm_session_id,
          expected_execution_revision: operation.expected_execution_revision,
          expected_fsm_state: :calling_llm
        )
        return unless state

        if ready.error
          # No successful operation result means no known committed execution
          # advance is safe to apply.
          state.invocation.event_sink.post(:llm_setup_failed, translated(ready.error))
          return
        end

        result = ready.result
        if result.runtime_projection
          event_loop.replace_agent_execution(
            operation.execution_id,
            execution: result.execution,
            runtime_projection: result.runtime_projection
          )
        else
          event_loop.replace_agent_execution(
            operation.execution_id,
            execution: result.execution
          )
        end
        state.invocation.acknowledge_runtime_snapshot(operation.runtime_snapshot)

        if result.error
          state.invocation.event_sink.post(:llm_setup_failed, translated(result.error))
          return
        end

        Agent::AgentInvocationSessionBuilder.start_prepared_provider_call(
          agent: @agent,
          runtime: Phronomy::Runtime.instance,
          event_sink: state.invocation.event_sink,
          invocation: state.invocation,
          projection: result.runtime_projection,
          streaming: operation.streaming
        )
      rescue => error
        state&.invocation&.event_sink&.post(:llm_setup_failed, translated(error))
      end

      # ----------------------------------------------------------------------
      # Approval resume
      # ----------------------------------------------------------------------

      def begin_resume_on_event_loop(request)
        runtime = Phronomy::Runtime.instance
        event_loop = runtime.event_loop
        state = event_loop.agent_execution_state(request.execution_id)
        unless state
          fail_task(
            request.result_task,
            Phronomy::ExecutionRehydrationRequiredError.new(
              "no live execution owner for #{request.execution_id}; durable rehydration is required"
            )
          )
          return
        end

        unless state.agent.equal?(@agent) && state.execution.status == :suspended
          fail_task(
            request.result_task,
            ArgumentError.new(
              "execution is not a suspended execution of this agent: #{request.execution_id}"
            )
          )
          return
        end

        approval = state.execution.approval_request || {}
        current_request_id = approval["id"] || approval[:id]
        unless current_request_id.to_s == request.approval_request_id
          fail_task(
            request.result_task,
            ArgumentError.new(
              "approval request does not match execution #{request.execution_id}"
            )
          )
          return
        end

        operation = ResumeCommitCommand.new(
          execution_id: state.execution_id,
          expected_execution_revision: state.execution.execution_revision,
          root: @agent.agent_root,
          execution: state.execution,
          approval_request_id: request.approval_request_id,
          approved: request.approved
        )
        resume_transition_started = false
        submitted = false
        event_loop.mark_agent_execution_admission(
          @agent.agent_id,
          execution_id: state.execution_id,
          state: :resuming
        )
        resume_transition_started = true
        task = runtime.offload.submit(on_full: :raise) do
          perform_resume_commit(operation)
        end
        submitted = true
        task.on_complete do |result, error|
          ready = ResumeCommitReady.new(
            coordinator: self,
            request: request,
            operation: operation,
            result: result,
            error: error
          )
          fail_task(request.result_task, runtime_rejected_error(:resume_commit)) unless
            post_control(runtime, ready)
        end
      rescue => error
        if resume_transition_started
          event_loop.mark_agent_execution_admission(
            @agent.agent_id,
            execution_id: state.execution_id,
            state: submitted ? :recovery_required : :suspended
          )
        end
        fail_task(request.result_task, translated(error))
        raise unless resume_transition_started
      end

      def perform_resume_commit(operation)
        current = operation.execution
        current_root = operation.root
        request = current.approval_request || {}
        request_id = request["id"] || request[:id]
        unless request_id.to_s == operation.approval_request_id
          raise ArgumentError,
            "approval request does not match execution #{current.execution_id}"
        end

        updated = next_root = nil
        @agent.persistence.transaction do |tx|
          decision_ref = tx.contents.put_json(
            "approval_request_id" => request_id.to_s,
            "approved" => operation.approved
          )
          decision_record = JournalRecord.new(
            agent_id: @agent.agent_id,
            execution_id: current.execution_id,
            kind: :approval_decided,
            channel: :approval,
            content_ref: decision_ref,
            context_generation: current_root.transcript_generation,
            context_candidate: false
          )
          updated = current.with(
            status: :active,
            phase: :resuming,
            working_records: current.working_records + [decision_record],
            approval_request: request.merge("approved" => operation.approved)
          )
          tx.executions.save(
            current.execution_id,
            expected_revision: current.execution_revision,
            execution: updated
          )
          next_root = current_root.with(
            agent_revision: current_root.agent_revision + 1,
            lifecycle_status: :active
          )
          tx.agents.save(
            current_root.agent_id,
            expected_revision: current_root.agent_revision,
            root: next_root
          )
        end
        ResumeCommitResult.new(execution: updated, root: next_root)
      end

      def apply_resume_commit_on_event_loop(ready)
        request = ready.request
        operation = ready.operation
        event_loop = Phronomy::Runtime.instance.event_loop
        state = event_loop.agent_execution_state(operation.execution_id)
        unless state && state.agent.equal?(@agent) &&
            state.execution.execution_revision == operation.expected_execution_revision &&
            state.execution.status == :suspended
          fail_task(
            request.result_task,
            Phronomy::Error.new(
              "stale approval resume result for #{operation.execution_id}"
            )
          )
          return
        end

        if ready.error
          event_loop.mark_agent_execution_admission(
            @agent.agent_id,
            execution_id: operation.execution_id,
            state: :recovery_required
          )
          fail_task(request.result_task, translated(ready.error))
          return
        end

        apply_agent_live_state(root: ready.result.root, appended_records: [])
        event_loop.mark_agent_execution_admission(
          @agent.agent_id,
          execution_id: operation.execution_id,
          state: :executing
        )
        event_loop.replace_agent_execution(
          operation.execution_id,
          execution: ready.result.execution
        )
        start_resume_on_event_loop(
          operation.execution_id,
          request.result_task,
          approved: request.approved,
          config: request.config
        )
      rescue => error
        state = event_loop&.agent_execution_state(operation.execution_id) if event_loop&.current?
        if state
          begin_terminal_commit_on_event_loop(
            state,
            request.result_task,
            state.invocation,
            error,
            fsm_session_id: state.fsm_session_id
          )
        else
          fail_task(request.result_task, translated(error))
        end
      end

      def start_resume_on_event_loop(execution_id, result_task, approved:, config:)
        runtime = Phronomy::Runtime.instance
        event_loop = runtime.event_loop
        state = event_loop.agent_execution_state(execution_id)
        invocation = state.invocation
        invocation.merge_config!(config)
        invocation.begin_approval_resume!(approved: approved)
        parent_session = Agent::AgentInvocationSessionBuilder.build_for_resume(
          agent_invocation: invocation,
          resume_event: :resume,
          resume_phase: :suspended,
          runtime: runtime
        )
        event_loop.replace_agent_execution(
          execution_id,
          invocation: invocation,
          fsm_session_id: parent_session.id
        )
        source_task = Phronomy::Task.deferred(name: "#{result_task.name}-source")
        source_task.on_complete do |completed, error|
          finish_on_event_loop(
            execution_id,
            result_task,
            completed || parent_session.context,
            error,
            fsm_session_id: parent_session.id
          )
        end
        event_loop.register(parent_session, completion: source_task)
        invocation.tool_invocations.each do |child|
          child_session = if child.awaiting_approval?
            Agent::ToolInvocationSessionBuilder.build_for_resume(
              tool_invocation: child,
              parent_event_sink: parent_session.event_sink,
              resume_event: approved ? :approve : :reject,
              resume_phase: :awaiting_approval,
              runtime: runtime
            )
          elsif !approved && child.authorized?
            Agent::ToolInvocationSessionBuilder.build_for_resume(
              tool_invocation: child,
              parent_event_sink: parent_session.event_sink,
              resume_event: :cancel,
              resume_phase: :authorized,
              runtime: runtime
            )
          end
          register_child(event_loop, child, child_session, parent_session.event_sink) if child_session
        end
      end

      def register_child(event_loop, child, session, parent_event_sink)
        completion = Phronomy::Task.deferred(name: "tool-session:#{child.id}")
        completion.on_complete do |_result, error|
          next unless error

          child.mark_framework_failed!(error)
          parent_event_sink.post(:tool_failed, {tool_invocation_id: child.id})
        end
        event_loop.register(session, completion: completion)
      end

      # ----------------------------------------------------------------------
      # Terminal durable barrier
      # ----------------------------------------------------------------------

      def finish_on_event_loop(execution_id, result_task, invocation, error, fsm_session_id:)
        event_loop = Phronomy::Runtime.instance.event_loop
        assert_event_loop!(event_loop)
        state = event_loop.agent_execution_state(execution_id)
        return fail_task(result_task, runtime_rejected_error(:terminal)) unless state

        unless state.fsm_session_id.to_s == fsm_session_id.to_s &&
            state.invocation.equal?(invocation)
          return fail_task(
            result_task,
            Phronomy::Error.new("stale Agent terminal callback for #{execution_id}")
          )
        end

        begin_terminal_commit_on_event_loop(
          state,
          result_task,
          invocation,
          error,
          fsm_session_id: fsm_session_id
        )
      end

      def begin_terminal_commit_on_event_loop(
        state,
        result_task,
        invocation,
        source_error,
        fsm_session_id:
      )
        operation = build_terminal_operation(
          execution: state.execution,
          root: @agent.agent_root,
          journal_records: @agent.send(:_journal_records_snapshot),
          invocation: invocation,
          source_error: source_error,
          fsm_session_id: fsm_session_id,
          state_required: true
        )
        delivery = TerminalDelivery.new(
          result_task: result_task,
          application_listener: invocation&.event_listener,
          approval_listener: invocation&.approval_listener,
          handoff_request: invocation&.handoff_request,
          handoff_manifest: state.runtime_projection&.manifest
        )
        submit_terminal_operation(operation, delivery)
      end

      def begin_terminal_without_session_on_event_loop(request:, prepared:, error:)
        return deliver_start_failure_on_event_loop(request, translated(error)) unless prepared&.execution

        operation = build_terminal_operation(
          execution: prepared.execution,
          root: prepared.root,
          journal_records: @agent.send(:_journal_records_snapshot),
          invocation: nil,
          source_error: error,
          fsm_session_id: nil,
          state_required: false
        )
        delivery = TerminalDelivery.new(
          result_task: request.result_task,
          application_listener: request.on_event,
          approval_listener: request.approval_listener,
          handoff_request: nil,
          handoff_manifest: nil
        )
        submit_terminal_operation(operation, delivery)
      end

      def build_terminal_operation(
        execution:,
        root:,
        journal_records:,
        invocation:,
        source_error:,
        fsm_session_id:,
        state_required:
      )
        TerminalCommitCommand.new(
          execution_id: execution.execution_id.to_s.freeze,
          fsm_session_id: fsm_session_id&.to_s&.freeze,
          expected_execution_revision: execution.execution_revision,
          root: root,
          journal_records: journal_records,
          execution: execution,
          runtime_snapshot: invocation ? invocation.runtime_snapshot : empty_runtime_snapshot,
          terminal_view: terminal_view(invocation, source_error),
          state_required: state_required
        )
      end

      def submit_terminal_operation(operation, delivery)
        runtime = Phronomy::Runtime.instance
        event_loop = runtime.event_loop
        terminal_transition_started = false
        event_loop.mark_agent_execution_admission(
          @agent.agent_id,
          execution_id: operation.execution_id,
          state: :terminalizing
        )
        terminal_transition_started = true
        task = runtime.offload.submit(on_full: :raise) do
          # Only the operation-specific immutable durable snapshot crosses the
          # worker boundary. Task/listener delivery state stays outside it.
          compute_terminal(operation)
        end
        task.on_complete do |outcome, error|
          ready = TerminalCommitReady.new(
            coordinator: self,
            operation: operation,
            delivery: delivery,
            outcome: outcome,
            error: error
          )
          fail_task(delivery.result_task, runtime_rejected_error(:terminal_apply)) unless
            post_control(runtime, ready)
        end
      rescue => error
        if terminal_transition_started
          event_loop.mark_agent_execution_admission(
            @agent.agent_id,
            execution_id: operation.execution_id,
            state: :recovery_required
          )
          fail_task(delivery.result_task, translated(error))
          return
        end

        fail_task(delivery.result_task, translated(error))
        raise
      end

      def terminal_view(invocation, source_error)
        TerminalView.new(
          phase: invocation&.phase,
          output: invocation&.output,
          usage: invocation&.usage,
          approval_request: invocation&.approval_request,
          rejected: invocation ? !!invocation.rejected : false,
          input_blocked: invocation ? invocation.input_blocked? : false,
          output_blocked: invocation ? invocation.output_blocked? : false,
          block_error: invocation&.block_error,
          invocation_error: invocation&.error,
          handoff: handoff_terminal_view(invocation&.handoff_request),
          callback_failure: invocation&.callback_failure,
          source_error: source_error
        )
      end

      def handoff_terminal_view(request)
        return unless request

        HandoffTerminalView.new(
          target_agent_id: request.handoff.target_agent.agent_id.to_s.freeze,
          responsibility: request.responsibility.to_s.freeze,
          selection_intent: request.selection_intent.to_h do |category, included|
            [category.to_s.freeze, !!included]
          end.freeze,
          llm_call_id: request.llm_call_id&.to_s&.freeze,
          tool_call_id: request.tool_call_id&.to_s&.freeze
        )
      end

      def empty_runtime_snapshot
        {llm_results: [].freeze, runtime_events: [].freeze, active_call: nil}.freeze
      end

      def compute_terminal(operation)
        view = operation.terminal_view
        if view.callback_failure
          return commit_failed_outcome(
            operation,
            view.callback_failure.to_stream_callback_error
          )
        end
        return commit_failed_outcome(operation, view.source_error) if view.source_error
        if view.phase == :suspended
          return commit_suspended(operation)
        end
        raise view.block_error if view.input_blocked || view.output_blocked
        raise view.invocation_error if view.invocation_error

        commit_completed(operation)
      rescue => caught
        commit_failed_outcome(operation, caught)
      end

      def commit_suspended(operation)
        current = operation.execution
        root = operation.root
        request = operation.terminal_view.approval_request
        runtime_snapshot = operation.runtime_snapshot
        suspended = next_root = nil

        @agent.persistence.transaction do |tx|
          encoded_records, call_records = encode_runtime_records(
            current,
            tx: tx,
            snapshot: runtime_snapshot,
            context_candidate: true,
            agent_root: root
          )
          request_ref = tx.contents.put_json(json_value(request.to_h))
          approval_record = JournalRecord.new(
            agent_id: @agent.agent_id,
            execution_id: current.execution_id,
            kind: :approval_required,
            channel: :approval,
            content_ref: request_ref,
            context_generation: root.transcript_generation,
            context_candidate: false
          )
          suspended = current.with(
            status: :suspended,
            phase: :approval,
            working_records: current.working_records + encoded_records + [approval_record],
            llm_calls: current.llm_calls + call_records,
            approval_request: json_value(request.to_h)
          )
          tx.executions.save(
            current.execution_id,
            expected_revision: current.execution_revision,
            execution: suspended
          )
          next_root = root.with(
            agent_revision: root.agent_revision + 1,
            lifecycle_status: :suspended
          )
          tx.agents.save(
            root.agent_id,
            expected_revision: root.agent_revision,
            root: next_root
          )
        end
        result = result_base(suspended, next_root).merge(
          suspended: true,
          approval_request: request
        )
        TerminalOutcome.new(
          type: :suspended,
          execution: suspended,
          root: next_root,
          appended_records: [].freeze,
          result: result.freeze,
          error: nil,
          approval_request: request
        )
      end

      def commit_completed(operation)
        current = operation.execution
        root = operation.root
        view = operation.terminal_view
        runtime_snapshot = operation.runtime_snapshot
        completed = next_root = appended = messages = nil

        @agent.persistence.transaction do |tx|
          encoded_records, call_records = encode_runtime_records(
            current,
            tx: tx,
            snapshot: runtime_snapshot,
            context_candidate: true,
            agent_root: root
          )
          output_ref = tx.contents.put_text(view.output.to_s)
          final_output_record = JournalRecord.new(
            agent_id: @agent.agent_id,
            execution_id: current.execution_id,
            kind: :final_output,
            channel: :audit,
            role: :assistant,
            content_ref: output_ref,
            context_generation: root.transcript_generation,
            context_candidate: false
          )
          completed_record = JournalRecord.new(
            agent_id: @agent.agent_id,
            execution_id: current.execution_id,
            kind: view.rejected ? :execution_rejected : :execution_completed,
            channel: :audit,
            content_ref: output_ref,
            context_generation: root.transcript_generation,
            context_candidate: false
          )
          all_records = current.working_records + encoded_records +
            [final_output_record, completed_record]
          appended = tx.journals.append(
            root.agent_id,
            expected_position: root.journal_position,
            records: all_records
          )
          completed = current.with(
            status: view.rejected ? :rejected : :completed,
            phase: :completed,
            working_records: [],
            llm_calls: current.llm_calls + call_records,
            approval_request: nil,
            result_ref: output_ref,
            terminal_reason: view.rejected ? "rejected" : "completed"
          )
          tx.executions.save(
            current.execution_id,
            expected_revision: current.execution_revision,
            execution: completed
          )
          context_changed = appended.any?(&:context_candidate)
          next_root = root.with(
            agent_revision: root.agent_revision + 1,
            context_revision: root.context_revision + (context_changed ? 1 : 0),
            journal_position: root.journal_position + appended.length,
            lifecycle_status: :idle
          )
          tx.agents.save(
            root.agent_id,
            expected_revision: root.agent_revision,
            root: next_root
          )

          # Materialize the caller-facing transcript through the transaction
          # view before commit. If materialization fails, the terminal durable
          # transition rolls back instead of committing and then attempting a
          # second terminal transition from a stale execution revision.
          records_after_commit = operation.journal_records + Array(appended)
          messages = transcript_messages(
            next_root,
            records_after_commit,
            persistence: tx
          )
        end
        result = result_base(completed, next_root).merge(
          output: view.output,
          rejected: view.rejected || nil,
          usage: view.usage,
          messages: messages
        ).compact
        TerminalOutcome.new(
          type: :completed,
          execution: completed,
          root: next_root,
          appended_records: Array(appended).freeze,
          result: result.freeze,
          error: nil,
          approval_request: nil
        )
      end

      def commit_failed_outcome(operation, error)
        translated_error = translated(error)
        current = operation.execution
        root = operation.root
        runtime_snapshot = operation.runtime_snapshot
        failed = next_root = appended = nil

        @agent.persistence.transaction do |tx|
          encoded_records, call_records = encode_runtime_records(
            current,
            tx: tx,
            snapshot: runtime_snapshot,
            context_candidate: false,
            agent_root: root
          )
          error_ref = tx.contents.put_json(
            "class" => translated_error.class.name,
            "message" => translated_error.message
          )
          audit_records = (current.working_records + encoded_records).map do |record|
            JournalRecord.from_h(
              record.to_h.merge("context_candidate" => false)
            )
          end
          terminal_status = terminal_status_for(translated_error)
          audit_records << JournalRecord.new(
            agent_id: @agent.agent_id,
            execution_id: current.execution_id,
            kind: execution_terminal_kind(terminal_status),
            channel: :audit,
            content_ref: error_ref,
            context_generation: root.transcript_generation,
            context_candidate: false
          )
          appended = tx.journals.append(
            root.agent_id,
            expected_position: root.journal_position,
            records: audit_records
          )
          failed = current.with(
            status: terminal_status,
            phase: terminal_status,
            working_records: [],
            llm_calls: current.llm_calls + call_records,
            error_ref: error_ref,
            terminal_reason: translated_error.class.name
          )
          tx.executions.save(
            current.execution_id,
            expected_revision: current.execution_revision,
            execution: failed
          )
          next_root = root.with(
            agent_revision: root.agent_revision + 1,
            journal_position: root.journal_position + appended.length,
            lifecycle_status: :idle
          )
          tx.agents.save(
            root.agent_id,
            expected_revision: root.agent_revision,
            root: next_root
          )
        end
        TerminalOutcome.new(
          type: :failed,
          execution: failed,
          root: next_root,
          appended_records: Array(appended).freeze,
          result: nil,
          error: translated_error,
          approval_request: nil
        )
      end

      def apply_terminal_commit_on_event_loop(ready)
        operation = ready.operation
        delivery = ready.delivery
        event_loop = Phronomy::Runtime.instance.event_loop
        state = event_loop.agent_execution_state(operation.execution_id)

        if operation.state_required
          unless state && state.agent.equal?(@agent) &&
              state.execution.execution_revision == operation.expected_execution_revision &&
              state.fsm_session_id.to_s == operation.fsm_session_id.to_s
            fail_task(
              delivery.result_task,
              Phronomy::Error.new("stale terminal result for #{operation.execution_id}")
            )
            return
          end
        end

        if ready.error
          admission_error = nil
          begin
            event_loop.mark_agent_execution_admission(
              @agent.agent_id,
              execution_id: operation.execution_id,
              state: :recovery_required
            )
          rescue => error
            # Losing the admission while a durable terminal outcome is unknown
            # is an Runtime authority violation. Settle the caller with the
            # original durable error, then fail EventLoop so no competing start
            # can be accepted from an unproven lineage.
            admission_error = error
          end
          callback_error = deliver_terminal(
            delivery.application_listener,
            :error,
            error: translated(ready.error)
          )
          settle_after_terminal(
            delivery.result_task,
            callback_error,
            :error,
            nil,
            translated(ready.error)
          )
          raise admission_error if admission_error
          return
        end

        outcome = ready.outcome
        apply_agent_live_state(
          root: outcome.root,
          appended_records: outcome.appended_records
        )
        if state
          state.invocation&.acknowledge_runtime_snapshot(operation.runtime_snapshot)
          event_loop.replace_agent_execution(
            operation.execution_id,
            execution: outcome.execution,
            fsm_session_id: (outcome.type == :suspended) ? nil : state.fsm_session_id
          )
        end

        case outcome.type
        when :suspended
          event_loop.mark_agent_execution_admission(
            @agent.agent_id,
            execution_id: operation.execution_id,
            state: :suspended
          )
          dispatch_approval_listener(delivery.approval_listener, outcome.approval_request)
          callback_error = deliver_terminal(
            delivery.application_listener,
            :approval_required,
            request: outcome.approval_request
          )
          settle_after_terminal(
            delivery.result_task,
            callback_error,
            :approval_required,
            outcome.result
          )
        when :completed
          event_loop.release_agent_execution(operation.execution_id) if state
          event_loop.release_agent_execution_admission(
            @agent.agent_id,
            execution_id: operation.execution_id
          )
          callback_error = deliver_terminal(delivery.application_listener, :done, outcome.result)
          settle_after_terminal(
            delivery.result_task,
            callback_error,
            :done,
            outcome.result
          )
        when :handed_off
          event_loop.release_agent_execution(operation.execution_id) if state
          event_loop.release_agent_execution_admission(
            @agent.agent_id,
            execution_id: operation.execution_id
          )
          result = outcome.result.merge(
            handoff_request: delivery.handoff_request,
            _phronomy_handoff_manifest: delivery.handoff_manifest
          ).freeze
          callback_error = deliver_terminal(delivery.application_listener, :handoff, result)
          settle_after_terminal(
            delivery.result_task,
            callback_error,
            :handoff,
            result
          )
        when :failed
          event_loop.release_agent_execution(operation.execution_id) if state
          event_loop.release_agent_execution_admission(
            @agent.agent_id,
            execution_id: operation.execution_id
          )
          type = terminal_event_type(outcome.error)
          callback_error = deliver_terminal(
            delivery.application_listener,
            type,
            error: outcome.error
          )
          settle_after_terminal(
            delivery.result_task,
            callback_error,
            type,
            nil,
            outcome.error
          )
        else
          fail_task(
            delivery.result_task,
            Phronomy::Error.new("unknown terminal outcome: #{outcome.type.inspect}")
          )
        end
      end

      # ----------------------------------------------------------------------
      # Durable record encoding helpers
      # ----------------------------------------------------------------------

      def encode_runtime_records(
        execution,
        tx:,
        snapshot:,
        context_candidate:,
        agent_root:
      )
        root = agent_root
        records = []
        calls = []

        snapshot.fetch(:llm_results).each_with_index do |item, index|
          outcome = item[:response]
          error = item[:error]
          llm_call_id = item.fetch(:llm_call_id).to_s
          intercepted = error.is_a?(ToolCallIntercepted)
          call_error = intercepted ? nil : error
          output_ref = assistant_output_ref(tx, outcome)
          assistant_ref = assistant_message_ref(tx, outcome)
          error_ref = if call_error
            tx.contents.put_json(
              "class" => call_error.class.name,
              "message" => call_error.message
            )
          end
          usage_ref = if outcome && !outcome.usage.empty?
            tx.contents.put_json(json_value(outcome.usage))
          end
          call = LLMCallRecord.new(
            llm_call_id: llm_call_id,
            execution_id: execution.execution_id,
            sequence: execution.llm_calls.length + index + 1,
            status: call_error ? :failed : :completed,
            manifest_ref: item.fetch(:manifest_ref),
            output_ref: output_ref,
            error_ref: error_ref,
            usage_ref: usage_ref,
            started_at: item.fetch(:started_at),
            completed_at: Time.now.utc.iso8601(6),
            metadata: {
              "streaming" => item[:streaming],
              "tool_call_intercepted" => intercepted,
              "assistant_outcome_captured" => !outcome.nil?,
              "tool_call_count" => outcome ? outcome.tool_calls.length : 0
            }
          )
          calls << call
          call_ref = tx.contents.put_json(call.to_h)
          records << JournalRecord.new(
            agent_id: @agent.agent_id,
            execution_id: execution.execution_id,
            llm_call_id: llm_call_id,
            kind: :llm_call_recorded,
            channel: :audit,
            content_ref: call_ref,
            context_generation: root.transcript_generation,
            context_candidate: false
          )

          if assistant_ref
            records << JournalRecord.new(
              agent_id: @agent.agent_id,
              execution_id: execution.execution_id,
              llm_call_id: llm_call_id,
              kind: :assistant_message,
              channel: :llm,
              role: :assistant,
              content_ref: assistant_ref,
              context_generation: root.transcript_generation,
              context_candidate: context_candidate,
              metadata: assistant_message_metadata(outcome)
            )
          end
        end

        if (active = snapshot[:active_call])
          abandoned = LLMCallRecord.new(
            llm_call_id: active.fetch(:llm_call_id),
            execution_id: execution.execution_id,
            sequence: execution.llm_calls.length + calls.length + 1,
            status: :cancelled,
            manifest_ref: active.fetch(:manifest_ref),
            started_at: active.fetch(:started_at),
            completed_at: Time.now.utc.iso8601(6),
            metadata: {
              "reason" => "execution_terminalized_before_provider_settlement"
            }
          )
          calls << abandoned
          records << JournalRecord.new(
            agent_id: @agent.agent_id,
            execution_id: execution.execution_id,
            llm_call_id: abandoned.llm_call_id,
            kind: :llm_call_recorded,
            channel: :audit,
            content_ref: tx.contents.put_json(abandoned.to_h),
            context_generation: root.transcript_generation,
            context_candidate: false
          )
        end

        snapshot.fetch(:runtime_events).each do |event|
          case event.type
          when :tool_call
            next
          when :tool_result
            payload = event.payload
            llm_call_id = payload[:llm_call_id] || payload["llm_call_id"]
            tool_call_id = payload.fetch(:tool_call_id).to_s
            tool_name = payload.fetch(:tool_name).to_s
            result_ref = put_runtime_content(tx, payload.fetch(:tool_result))
            records << JournalRecord.new(
              agent_id: @agent.agent_id,
              execution_id: execution.execution_id,
              llm_call_id: llm_call_id,
              kind: :tool_result,
              channel: :tool,
              content_ref: result_ref,
              causation_id: tool_call_id,
              context_generation: root.transcript_generation,
              context_candidate: false,
              metadata: {
                "tool_call_id" => tool_call_id,
                "tool_name" => tool_name
              }
            )

            message_payload = if payload.key?(:tool_message)
              payload.fetch(:tool_message)
            else
              payload.fetch("tool_message")
            end
            records << JournalRecord.new(
              agent_id: @agent.agent_id,
              execution_id: execution.execution_id,
              llm_call_id: llm_call_id,
              kind: :tool_message,
              channel: :tool,
              role: :tool,
              content_ref: tx.contents.put_json(json_value(message_payload)),
              causation_id: tool_call_id,
              context_generation: root.transcript_generation,
              context_candidate: context_candidate,
              metadata: {
                "tool_call_id" => tool_call_id,
                "tool_name" => tool_name
              }
            )
          end
        end
        [records, calls]
      end

      def assistant_message_ref(tx, outcome)
        return unless outcome

        payload = {
          "role" => "assistant",
          "content" => json_value(outcome.content),
          "tool_calls" => json_value(Array(outcome.tool_calls)),
          "model_id" => outcome.metadata["model_id"]
        }.compact
        tx.contents.put_json(payload)
      end

      def assistant_message_metadata(outcome)
        calls = Array(outcome&.tool_calls)
        {
          "tool_call_ids" => calls.map { |call| call.fetch("id").to_s },
          "tool_names" => calls.map { |call| call.fetch("name").to_s }
        }
      end

      def assistant_output_ref(tx, outcome)
        return unless outcome&.content_present?

        content = outcome.content
        text = content.is_a?(String) ? content : Phronomy::CanonicalJSON.dump(content)
        tx.contents.put_text(text)
      end

      def put_runtime_content(tx, value)
        value.is_a?(String) ?
          tx.contents.put_text(value) : tx.contents.put_json(json_value(value))
      end

      # ----------------------------------------------------------------------
      # EventLoop validation/apply helpers
      # ----------------------------------------------------------------------

      def authoritative_state_for_operation(
        execution_id:,
        fsm_session_id:,
        expected_execution_revision:,
        expected_fsm_state:
      )
        event_loop = Phronomy::Runtime.instance.event_loop
        state = event_loop.agent_execution_state(execution_id)
        authoritative = state &&
          state.agent.equal?(@agent) &&
          state.execution.execution_revision == expected_execution_revision &&
          state.fsm_session_id.to_s == fsm_session_id.to_s &&
          event_loop.fsm_session_state(fsm_session_id) == expected_fsm_state
        return state if authoritative

        Phronomy.configuration.logger&.warn(
          "[Phronomy] Dropped stale Agent operation result: " \
          "execution_id=#{execution_id} fsm_session_id=#{fsm_session_id}"
        )
        nil
      rescue
        nil
      end

      def validate_live_session!(state, invocation, fsm_session_id)
        unless state && state.agent.equal?(@agent) &&
            state.invocation.equal?(invocation) &&
            state.fsm_session_id.to_s == fsm_session_id.to_s
          raise Phronomy::Error,
            "Agent operation does not belong to the current live FSMSession"
        end
      end

      def apply_agent_live_state(root:, appended_records:)
        event_loop = Phronomy::Runtime.instance.event_loop
        assert_event_loop!(event_loop)
        @agent.send(:_append_journal_records, appended_records)
        @agent.__replace_root(root)
      end

      def assert_event_loop!(event_loop)
        return if event_loop.current?

        raise Phronomy::Error,
          "ExecutionCoordinator live-state apply must run on EventLoop"
      end

      def assert_local_durable_base!(tx, root)
        tx.assert_agent_watermark!(
          agent_id: root.agent_id,
          agent_revision: root.agent_revision,
          journal_position: root.journal_position
        )
      end

      def transcript_messages(root, journal_records, persistence: @agent.persistence)
        materializer = RubyLLMMaterializer.new(
          agent: @agent,
          persistence: persistence
        )
        materializer.materialize_journal_records(
          JournalProjection.new(
            agent_root: root,
            records: journal_records
          ).transcript_records
        )
      end

      def result_base(execution, root)
        {
          agent_id: root.agent_id,
          execution_id: execution.execution_id,
          agent_revision: root.agent_revision,
          context_revision: root.context_revision,
          journal_position: root.journal_position
        }
      end

      def context_policy_for(execution)
        descriptor_hash = execution.metadata.fetch("context_policy") do
          ContextPolicies::Default.new.descriptor.to_h
        end
        descriptor = ContextPolicyDescriptor.from_h(descriptor_hash)
        ContextPolicyRegistry.default.resolve(descriptor)
      end

      def deliver_terminal(listener, type, payload)
        return nil unless listener

        @agent.send(
          :_deliver_stream_event,
          listener,
          StreamEvent.new(type: type, payload: payload)
        )
      end

      def dispatch_approval_listener(listener, request)
        return unless listener

        Phronomy::Runtime.instance.offload.submit(on_full: :raise) do
          listener.call(request)
        end
      rescue => error
        Phronomy.configuration.logger&.warn(
          "[Phronomy] approval listener dispatch failed: #{error.class}: #{error.message}"
        )
      end

      def settle_after_terminal(
        result_task,
        callback_error,
        event_type,
        result,
        execution_error = nil
      )
        if callback_error
          policy = Phronomy.configuration.stream_callback_error_policy
          @agent.send(
            :_report_stream_callback_error,
            callback_error,
            event: StreamEvent.new(
              type: event_type,
              payload: result || {error: execution_error}
            ),
            execution_id: result&.fetch(:execution_id, nil),
            callback_error_policy: policy
          )
          if policy == :fail_task && execution_error.nil?
            return fail_task(
              result_task,
              @agent.send(
                :_build_stream_callback_error,
                event_type: event_type,
                callback_error: callback_error,
                result: result
              )
            )
          end
        end
        execution_error ?
          fail_task(result_task, execution_error) : complete_task(result_task, result)
      end

      def terminal_event_type(error)
        return :timeout if error.is_a?(Phronomy::TimeoutError)
        return :cancelled if error.is_a?(Phronomy::CancellationError)

        :error
      end

      def json_value(value)
        case value
        when Hash
          value.to_h { |key, child| [key.to_s, json_value(child)] }
        when Array
          value.map { |child| json_value(child) }
        when String, Integer, Float, TrueClass, FalseClass, NilClass
          value
        when Symbol
          value.to_s
        else
          if value.respond_to?(:to_h)
            json_value(value.to_h)
          else
            raise ArgumentError,
              "unsupported canonical runtime value: #{value.class}"
          end
        end
      end

      def terminal_status_for(error)
        if defined?(Phronomy::CancellationError) &&
            error.is_a?(Phronomy::CancellationError)
          return :cancelled
        end
        if defined?(Phronomy::FilterBlockError) &&
            error.is_a?(Phronomy::FilterBlockError)
          return :blocked
        end

        :failed
      end

      def execution_terminal_kind(status)
        {
          cancelled: :execution_cancelled,
          blocked: :execution_blocked,
          failed: :execution_failed
        }.fetch(status)
      end

      def post_control(runtime, command)
        runtime.event_loop.post(
          Phronomy::Event.new(
            type: :agent_control,
            target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
            payload: {command: command}
          )
        )
      rescue Phronomy::RuntimeShutdownError
        false
      end

      def runtime_rejected_error(operation)
        Phronomy::RuntimeShutdownError.new(
          "EventLoop is not accepting Agent #{operation} control delivery"
        )
      end

      def translated(error)
        @agent.send(:_translated_error, error)
      end

      def complete_task(task, result)
        @agent.send(:_complete_result_task, task, result)
      end

      def fail_task(task, error)
        @agent.send(:_fail_result_task, task, error)
      end
    end
  end
end
