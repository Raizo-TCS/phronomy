# frozen_string_literal: true

require_relative "../../engine/concurrency/worker_input_restricted"

require "time"
require "securerandom"

module Phronomy
  module Agent
    class ExecutionCoordinator
      include Phronomy::Concurrency::WorkerInputRestricted

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

      # Recovery -> execution-owner commands. These stay on EventLoop and do
      # not carry persistence readers or arbitrary private method names.
      RecoverPreparationCommand = Data.define(
        :coordinator, :execution_id, :expected_execution_revision,
        :result_task, :load_completion
      )
      ContinueRecoveredCommand = Data.define(
        :coordinator, :execution_id, :expected_execution_revision,
        :continuation, :invocation, :runtime_projection, :result_task, :error
      )
      SessionFinishedCommand = Data.define(
        :coordinator, :execution_id, :result_task, :invocation, :error, :fsm_session_id
      )

      # EventLoop -> Offload operation-specific immutable snapshots.
      InitialPreparationCommand = InitialPreparation::Command
      ProviderDispatchPreparationCommand = DispatchPreparation::ProviderCommand
      ToolDispatchPreparationCommand = DispatchPreparation::ToolCommand
      ProviderDispatchPreparationReconciliationCommand = DispatchPreparation::ProviderReconciliationCommand
      ToolDispatchPreparationReconciliationCommand = DispatchPreparation::ToolReconciliationCommand
      ResumeCommitCommand = ApprovalResumeCommit::Command
      HandoffTerminalView = ExecutionOutcomeCommitter::HandoffTerminalView
      TerminalView = ExecutionOutcomeCommitter::TerminalView
      TerminalCommitCommand = ExecutionOutcomeCommitter::Command
      TerminalDelivery = Data.define(
        :result_task, :application_listener, :approval_listener,
        :handoff_request, :handoff_manifest
      )

      # Offload -> EventLoop operation results. No live Agent/Invocation object is
      # mutated by a worker; these values are validated and applied on EventLoop.
      InitialPreparationResult = InitialPreparation::Result
      ProviderDispatchPreparationResult = DispatchPreparation::ProviderResult
      ToolDispatchPreparationResult = DispatchPreparation::ToolResult
      ProviderDispatchPreparationReconciliationResult = DispatchPreparation::ProviderReconciliationResult
      ToolDispatchPreparationReconciliationResult = DispatchPreparation::ToolReconciliationResult
      ResumeCommitResult = ApprovalResumeCommit::Result
      TerminalOutcome = ExecutionOutcomeCommitter::Outcome

      InitialPreparationReady = Data.define(
        :coordinator, :request, :result, :error
      )
      InitialPreparationRecoveryReady = Data.define(
        :coordinator, :execution_id, :expected_execution_revision,
        :result_task, :load_completion, :result, :error
      )
      ProviderDispatchPreparationReady = Data.define(
        :coordinator, :operation, :result, :error
      )
      ToolDispatchPreparationReady = Data.define(
        :coordinator, :operation, :result, :error
      )
      ProviderDispatchPreparationReconciliationReady = Data.define(
        :coordinator, :command, :result, :error
      )
      ToolDispatchPreparationReconciliationReady = Data.define(
        :coordinator, :command, :result, :error
      )
      ResumeCommitReady = Data.define(
        :coordinator, :request, :operation, :result, :error
      )
      TerminalCommitReady = Data.define(
        :coordinator, :operation, :delivery, :outcome, :error
      )
      DeferredTerminalCommand = Data.define(
        :coordinator, :execution_id, :result_task, :invocation,
        :source_error, :fsm_session_id
      )

      PreparationOutcomeUnknownError = DispatchPreparation::OutcomeUnknownError
      private_constant :PreparationOutcomeUnknownError

      def initialize(agent)
        @agent = agent
        @initial_preparation = InitialPreparation.new(agent: agent, persistence: agent.persistence)
        @dispatch_preparation = DispatchPreparation.new(agent: agent, persistence: agent.persistence)
        @approval_resume_commit = ApprovalResumeCommit.new(agent_id: agent.agent_id, persistence: agent.persistence)
        @outcome_committer = build_outcome_committer
      end

      def start(
        input, config: {}, mode: :invoke,
        approval_policy: nil, approval_listener: nil, on_event: nil
      )
        @agent.send(:__assert_live_agent!)
        @agent.send(:_reject_removed_generic_identity_keys!, config)
        result_task = Phronomy::TaskResult.deferred(name: "agent-#{@agent.agent_id}-#{mode}")
        if config[:invocation_context]
          binding = Phronomy::Concurrency::OperationBinding.new(
            invocation_context: config[:invocation_context],
            cancellation_token: config[:cancellation_token]
          )
          binding.bind(result_task)
          config = config.merge(cancellation_token: binding.token)
        end
        command = StartCommand.new(
          coordinator: self,
          input: input,
          config: @agent.__invocation_config(config).dup.freeze,
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
        result_task = Phronomy::TaskResult.deferred(
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

      # Called only from an Agent FSMSession external-operation dispatch state on
      # EventLoop. Each method captures one operation-specific immutable snapshot
      # and sends only that snapshot to OffloadPool.
      # @api private
      def prepare_provider_dispatch(invocation, event_sink:, streaming:)
        state = dispatch_preparation_state!(
          invocation, event_sink, phase: :calling_llm, kind: "Provider"
        )
        operation = capture_provider_preparation(
          state, invocation, fsm_session_id: event_sink.fsm_session_id, streaming: streaming
        )
        submit_provider_dispatch_preparation(operation)
        nil
      rescue => error
        event_sink.post(:llm_setup_failed, translated(error))
        nil
      end

      # @api private
      def prepare_tool_dispatch(invocation, event_sink:)
        state = dispatch_preparation_state!(
          invocation, event_sink, phase: :dispatching_tools, kind: "Tool"
        )
        operation = capture_tool_preparation(
          state, invocation, fsm_session_id: event_sink.fsm_session_id
        )
        submit_tool_dispatch_preparation(operation)
        nil
      rescue => error
        event_sink.post(:tool_setup_failed, translated(error))
        nil
      end

      def submit_provider_dispatch_preparation(operation)
        runtime = Phronomy::Runtime.instance
        task = Phronomy::Storage::AsyncClient.submit(pool: runtime.offload) do
          @dispatch_preparation.prepare_provider(operation)
        end
        task.on_complete do |result, error|
          ready = ProviderDispatchPreparationReady.new(
            coordinator: self,
            operation: operation,
            result: result,
            error: error
          )
          unless post_control(runtime, ready)
            Phronomy.configuration.logger&.warn(
              "[Phronomy] EventLoop rejected Provider dispatch preparation result for " \
              "#{operation.execution_id}"
            )
          end
        end
      end

      def submit_tool_dispatch_preparation(operation)
        runtime = Phronomy::Runtime.instance
        task = Phronomy::Storage::AsyncClient.submit(pool: runtime.offload) do
          @dispatch_preparation.prepare_tools(operation)
        end
        task.on_complete do |result, error|
          ready = ToolDispatchPreparationReady.new(
            coordinator: self,
            operation: operation,
            result: result,
            error: error
          )
          unless post_control(runtime, ready)
            Phronomy.configuration.logger&.warn(
              "[Phronomy] EventLoop rejected Tool dispatch preparation result for " \
              "#{operation.execution_id}"
            )
          end
        end
      end

      def submit_provider_dispatch_preparation_reconciliation(operation, uncertainty)
        # simplecov:disable
        runtime = Phronomy::Runtime.instance
        command = ProviderDispatchPreparationReconciliationCommand.new(
          operation: operation,
          intended_result: uncertainty.intended_result,
          original_error: uncertainty.original_error
        )
        task = Phronomy::Storage::AsyncClient.submit(pool: runtime.offload) do
          @dispatch_preparation.reconcile_provider(command)
        end
        task.on_complete do |result, error|
          ready = ProviderDispatchPreparationReconciliationReady.new(
            coordinator: self,
            command: command,
            result: result,
            error: error
          )
          unless post_control(runtime, ready)
            Phronomy.configuration.logger&.warn(
              "[Phronomy] EventLoop rejected Provider dispatch reconciliation result for #{operation.execution_id}"
            )
          end
        end
      rescue => error
        mark_barrier_recovery_required(operation, error)
        # simplecov:enable
      end

      def submit_tool_dispatch_preparation_reconciliation(operation, uncertainty)
        # simplecov:disable
        runtime = Phronomy::Runtime.instance
        command = ToolDispatchPreparationReconciliationCommand.new(
          operation: operation,
          intended_result: uncertainty.intended_result,
          original_error: uncertainty.original_error
        )
        task = Phronomy::Storage::AsyncClient.submit(pool: runtime.offload) do
          @dispatch_preparation.reconcile_tools(command)
        end
        task.on_complete do |result, error|
          ready = ToolDispatchPreparationReconciliationReady.new(
            coordinator: self,
            command: command,
            result: result,
            error: error
          )
          unless post_control(runtime, ready)
            Phronomy.configuration.logger&.warn(
              "[Phronomy] EventLoop rejected Tool dispatch reconciliation result for #{operation.execution_id}"
            )
          end
        end
      rescue => error
        mark_barrier_recovery_required(operation, error)
        # simplecov:enable
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
        when RecoverPreparationCommand
          recover_preparation_on_event_loop(command)
        when ContinueRecoveredCommand
          continue_recovered_on_event_loop(command)
        when SessionFinishedCommand
          finish_on_event_loop(command.execution_id, command.result_task,
            command.invocation, command.error, fsm_session_id: command.fsm_session_id)
        when InitialPreparationReady
          apply_initial_preparation_on_event_loop(command)
        when InitialPreparationRecoveryReady
          apply_initial_preparation_recovery_on_event_loop(command)
        when ProviderDispatchPreparationReady
          apply_provider_dispatch_preparation_on_event_loop(command)
        when ToolDispatchPreparationReady
          apply_tool_dispatch_preparation_on_event_loop(command)
        when ProviderDispatchPreparationReconciliationReady
          apply_provider_dispatch_preparation_reconciliation_on_event_loop(command)
        when ToolDispatchPreparationReconciliationReady
          apply_tool_dispatch_preparation_reconciliation_on_event_loop(command)
        when ResumeCommand
          begin_resume_on_event_loop(command)
        when ResumeCommitReady
          apply_resume_commit_on_event_loop(command)
        when TerminalCommitReady
          apply_terminal_commit_on_event_loop(command)
        when DeferredTerminalCommand
          resume_deferred_terminal_on_event_loop(command)
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
        scope = request.config[:invocation_context]&.__execution_scope
        if scope && (!scope.__open? || request.config[:cancellation_token]&.cancelled?)
          deliver_start_failure_on_event_loop(request, scope.__cancellation_error)
          return
        end
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
        Phronomy::Agent::ExecutionRegistry.for(event_loop).admit_agent_execution(
          @agent.agent_id,
          owner_token: request.admission_token
        )
        admitted = true

        # Ownership purge may begin on an application thread between the first
        # live-owner check and EventLoop admission. Re-check after the slot is
        # installed: once this check succeeds, purge observes the admission and
        # must abort instead of deleting the Agent underneath this start.
        @agent.send(:__assert_live_agent!)

        operation = capture_initial_preparation(request, root)
        task = Phronomy::Storage::AsyncClient.submit(pool: runtime.offload) do
          @initial_preparation.prepare(operation)
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
            Phronomy::Agent::ExecutionRegistry.for(event_loop).mark_agent_admission_recovery_required(
              @agent.agent_id,
              owner_token: request.admission_token
            )
          else
            Phronomy::Agent::ExecutionRegistry.for(event_loop).release_agent_execution_admission(
              @agent.agent_id,
              owner_token: request.admission_token
            )
          end
        end
        deliver_start_failure_on_event_loop(request, translated(error))
      end

      def capture_initial_preparation(request, root)
        InitialPreparationCommand.new(
          root: root,
          journal_records: @agent.send(:_journal_records_snapshot),
          input: request.input,
          config: request.config,
          preparation_replayable: initial_preparation_replayable?(
            request.input,
            request.config,
            request.approval_policy
          )
        )
      end

      def initial_preparation_replayable?(input, config, approval_policy)
        return false unless input.is_a?(String)
        return false unless approval_policy.nil?
        if config.key?(:phronomy_handoff_bindings) ||
            config.key?(:phronomy_handoff_context)
          return false unless config[:phronomy_coordination]&.fetch("kind", nil) == "handoff"
        end

        invocation_context = config[:invocation_context]
        return true unless invocation_context

        %i[approval_policy redaction_policy token_budget].none? do |name|
          invocation_context.respond_to?(name) &&
            !invocation_context.public_send(name).nil?
        end
      end

      def apply_initial_preparation_on_event_loop(ready)
        request = ready.request
        event_loop = Phronomy::Runtime.instance.event_loop
        if ready.error
          Phronomy::Agent::ExecutionRegistry.for(event_loop).mark_agent_admission_recovery_required(
            @agent.agent_id,
            owner_token: request.admission_token
          )
          deliver_start_failure_on_event_loop(request, translated(ready.error))
          return
        end

        result = ready.result
        case result.admission_outcome
        when :not_established
          Phronomy::Agent::ExecutionRegistry.for(event_loop).release_agent_execution_admission(
            @agent.agent_id,
            owner_token: request.admission_token
          )
          deliver_start_failure_on_event_loop(request, result.error)
          return
        when :outcome_unknown, :recovery_required
          Phronomy::Agent::ExecutionRegistry.for(event_loop).mark_agent_admission_recovery_required(
            @agent.agent_id,
            owner_token: request.admission_token
          )
          deliver_start_failure_on_event_loop(request, result.error)
          return
        when :active, :terminal
          Phronomy::Agent::ExecutionRegistry.for(event_loop).bind_agent_execution_admission(
            @agent.agent_id,
            owner_token: request.admission_token,
            execution_id: result.execution.execution_id
          )
        else
          Phronomy::Agent::ExecutionRegistry.for(event_loop).mark_agent_admission_recovery_required(
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
          Phronomy::Agent::ExecutionRegistry.for(event_loop).release_agent_execution_admission(
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
        Phronomy::Tracing::Automatic.observe_task(
          request.result_task,
          "agent.execution",
          input: request.input,
          agent_id: @agent.agent_id,
          execution_id: prepared.execution.execution_id,
          mode: request.mode,
          **@agent.send(:_build_caller_meta, prepared.config)
        )
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
        Phronomy::Agent::ExecutionRegistry.for(event_loop).install_agent_execution(
          execution_id: prepared.execution.execution_id,
          agent: @agent,
          coordinator: self,
          execution: prepared.execution,
          runtime_projection: prepared.runtime_projection,
          base_manifest: prepared.runtime_projection.manifest,
          invocation: session.context,
          fsm_session_id: session.id
        )
        Phronomy::Agent::ExecutionRegistry.for(event_loop).register_agent_completion_waiter(
          prepared.execution.execution_id,
          request.result_task
        )
        execution_session_runner(runtime).register(
          session, request.result_task
        )
      # simplecov:disable
      rescue => _error
        Phronomy::Agent::ExecutionRegistry.for(event_loop).release_agent_execution(prepared.execution.execution_id) if
          event_loop&.current? && Phronomy::Agent::ExecutionRegistry.for(event_loop).agent_execution_state(prepared.execution.execution_id)
        raise
      end
      # simplecov:enable

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

      # Restarts only the replay-safe initial preparation region of an already
      # durably admitted logical Execution. Runtime-only caller state is not
      # reconstructed here; the durable preparation inputs are authoritative.
      # @api private
      def start_initial_preparation_recovery_on_event_loop(
        execution,
        result_task,
        load_completion:
      )
        runtime = Phronomy::Runtime.instance
        event_loop = runtime.event_loop
        assert_event_loop!(event_loop)
        state = Phronomy::Agent::ExecutionRegistry.for(event_loop).agent_execution_state(execution.execution_id)
        unless state && state.agent.equal?(@agent) &&
            state.execution.execution_revision == execution.execution_revision &&
            state.execution.status == :preparing &&
            state.execution.phase.to_sym == :preparing
          error = Phronomy::ExecutionRehydrationRequiredError.new(
            "stale :preparing Recovery installation for #{execution.execution_id}"
          )
          fail_task(result_task, error)
          load_completion.fail(error)
          return
        end

        operation = InitialPreparation::RecoveryCommand.new(
          execution: execution,
          root: @agent.agent_root,
          journal_records: @agent.send(:_journal_records_snapshot)
        )
        task = Phronomy::Storage::AsyncClient.submit(pool: runtime.offload) do
          @initial_preparation.recover(operation)
        end
        task.on_complete do |result, error|
          ready = InitialPreparationRecoveryReady.new(
            coordinator: self,
            execution_id: execution.execution_id.to_s.freeze,
            expected_execution_revision: execution.execution_revision,
            result_task: result_task,
            load_completion: load_completion,
            result: result,
            error: error
          )
          unless post_control(runtime, ready)
            rejected = runtime_rejected_error(:initial_preparation_recovery)
            fail_task(result_task, rejected)
            load_completion.fail(rejected)
          end
        end
      rescue => error
        # simplecov:disable
        begin
          if defined?(event_loop) && event_loop.current?
            release_initial_preparation_recovery_runtime_state(
              event_loop,
              execution.execution_id
            )
          end
        rescue
          nil
        end
        translated_error = translated(error)
        fail_task(result_task, translated_error)
        load_completion.fail(translated_error)
        # simplecov:enable
      end

      def apply_initial_preparation_recovery_on_event_loop(ready)
        event_loop = Phronomy::Runtime.instance.event_loop
        state = Phronomy::Agent::ExecutionRegistry.for(event_loop).agent_execution_state(ready.execution_id)
        unless state && state.agent.equal?(@agent) &&
            state.execution.execution_revision == ready.expected_execution_revision &&
            state.execution.status == :preparing &&
            state.execution.phase.to_sym == :preparing
          error = Phronomy::ExecutionRehydrationRequiredError.new(
            "stale initial preparation Recovery result for #{ready.execution_id}"
          )
          fail_task(ready.result_task, error)
          ready.load_completion.fail(error)
          return
        end

        if ready.error
          release_initial_preparation_recovery_runtime_state(
            event_loop,
            ready.execution_id
          )
          error = translated(ready.error)
          fail_task(ready.result_task, error)
          ready.load_completion.fail(error)
          return
        end

        result = ready.result
        case result.admission_outcome
        when :terminal
          settle_failed_preparation_recovery_on_event_loop(ready, event_loop)
          ready.load_completion.complete(@agent)
        when :active
          restart_prepared_execution_on_event_loop(ready, event_loop)
          ready.load_completion.complete(@agent)
        else
          error = Phronomy::ExecutionRehydrationRequiredError.new(
            "unexpected initial preparation Recovery outcome: #{result.admission_outcome.inspect}"
          )
          release_initial_preparation_recovery_runtime_state(
            event_loop,
            ready.execution_id
          )
          fail_task(ready.result_task, error)
          ready.load_completion.fail(error)
        end
      rescue => error
        # simplecov:disable
        begin
          release_initial_preparation_recovery_runtime_state(
            event_loop,
            ready.execution_id
          )
        rescue
          nil
        end
        translated_error = translated(error)
        fail_task(ready.result_task, translated_error)
        ready.load_completion.fail(translated_error)
        # simplecov:enable
      end

      def settle_failed_preparation_recovery_on_event_loop(ready, event_loop)
        result = ready.result
        apply_agent_live_state(
          root: result.root,
          appended_records: result.appended_records
        )
        Phronomy::Agent::ExecutionRegistry.for(event_loop).replace_agent_execution(
          ready.execution_id,
          execution: result.execution
        )
        Phronomy::Agent::ExecutionRegistry.for(event_loop).release_agent_execution(ready.execution_id)
        Phronomy::Agent::ExecutionRegistry.for(event_loop).release_agent_execution_admission(
          @agent.agent_id,
          execution_id: ready.execution_id
        )
        event_type = terminal_event_type(result.error)
        callback_error = deliver_terminal(
          @agent.send(:_phronomy_event_listener),
          event_type,
          error: result.error
        )
        settle_after_terminal(
          ready.result_task,
          callback_error,
          event_type,
          nil,
          result.error
        )
      end

      def restart_prepared_execution_on_event_loop(ready, event_loop)
        result = ready.result
        apply_agent_live_state(
          root: result.root,
          appended_records: result.appended_records
        )
        Phronomy::Agent::ExecutionRegistry.for(event_loop).release_agent_execution(ready.execution_id)
        mode = (
          result.execution.metadata[ExecutionMetadata::INVOCATION_MODE_KEY] ||
            "invoke"
        ).to_sym
        request = StartCommand.new(
          coordinator: self,
          input: result.filtered_input,
          config: result.config,
          mode: mode,
          approval_policy: nil,
          approval_listener: nil,
          on_event: @agent.send(:_phronomy_event_listener),
          result_task: ready.result_task,
          admission_token: Object.new.freeze
        )
        begin
          register_initial_session_on_event_loop(request, result)
        rescue => error
          begin_terminal_without_session_on_event_loop(
            request: request,
            prepared: result,
            error: error
          )
        end
      end

      def release_initial_preparation_recovery_runtime_state(
        event_loop,
        execution_id
      )
        state = Phronomy::Agent::ExecutionRegistry.for(event_loop).agent_execution_state(execution_id)
        Phronomy::Agent::ExecutionRegistry.for(event_loop).release_agent_execution(execution_id) if state
        Phronomy::Agent::ExecutionRegistry.for(event_loop).release_agent_execution_admission(
          @agent.agent_id,
          execution_id: execution_id
        )
      end

      # ----------------------------------------------------------------------
      # External-operation causal durable barriers
      # ----------------------------------------------------------------------

      def dispatch_preparation_state!(invocation, event_sink, phase:, kind:)
        event_loop = Phronomy::Runtime.instance.event_loop
        assert_event_loop!(event_loop)
        state = ExecutionRegistry.for(event_loop).agent_execution_state(invocation.execution_id)
        validate_live_session!(state, invocation, event_sink.fsm_session_id)
        unless event_loop.fsm_session_state(event_sink.fsm_session_id) == phase
          raise Phronomy::Error,
            "#{kind} dispatch preparation requires the owning FSMSession to be in #{phase.inspect}"
        end
        state
      end

      def capture_provider_preparation(state, invocation, fsm_session_id:, streaming:)
        ProviderDispatchPreparationCommand.new(
          execution_id: state.execution_id,
          fsm_session_id: fsm_session_id.to_s.freeze,
          expected_execution_revision: state.execution.execution_revision,
          root: @agent.agent_root,
          journal_records: @agent.send(:_journal_records_snapshot),
          execution: state.execution,
          base_manifest: state.base_manifest,
          invocation_config: invocation.config.dup.freeze,
          runtime_snapshot: invocation.runtime_snapshot,
          streaming: !!streaming,
          pending_llm_call_id: SecureRandom.uuid.to_s.freeze,
          pending_llm_started_at: Time.now.utc.iso8601(6).freeze
        )
      end

      def capture_tool_preparation(state, invocation, fsm_session_id:)
        tool_batch_snapshot = ExecutionMetadata.build_tool_batch_snapshot(invocation)
        if tool_batch_snapshot.empty?
          raise Phronomy::Error, "Tool dispatch preparation requires a non-empty Tool batch"
        end

        ToolDispatchPreparationCommand.new(
          execution_id: state.execution_id,
          fsm_session_id: fsm_session_id.to_s.freeze,
          expected_execution_revision: state.execution.execution_revision,
          root: @agent.agent_root,
          execution: state.execution,
          runtime_snapshot: invocation.runtime_snapshot,
          tool_batch_snapshot: tool_batch_snapshot
        )
      end

      def apply_provider_dispatch_preparation_on_event_loop(ready)
        operation = ready.operation
        state = authoritative_state_for_operation(
          execution_id: operation.execution_id,
          fsm_session_id: operation.fsm_session_id,
          expected_execution_revision: operation.expected_execution_revision,
          expected_fsm_state: :calling_llm
        )
        return unless state

        if ready.error
          if ready.error.is_a?(PreparationOutcomeUnknownError)
            submit_provider_dispatch_preparation_reconciliation(
              operation,
              ready.error
            )
          else
            state.invocation.event_sink.post(:llm_setup_failed, translated(ready.error))
          end
          return
        end

        apply_confirmed_provider_dispatch_preparation_on_event_loop(
          operation,
          ready.result,
          state
        )
      rescue => error
        state&.invocation&.event_sink&.post(:llm_setup_failed, translated(error))
      end

      def apply_tool_dispatch_preparation_on_event_loop(ready)
        operation = ready.operation
        state = authoritative_state_for_operation(
          execution_id: operation.execution_id,
          fsm_session_id: operation.fsm_session_id,
          expected_execution_revision: operation.expected_execution_revision,
          expected_fsm_state: :dispatching_tools
        )
        return unless state

        if ready.error
          if ready.error.is_a?(PreparationOutcomeUnknownError)
            submit_tool_dispatch_preparation_reconciliation(
              operation,
              ready.error
            )
          else
            state.invocation.event_sink.post(:tool_setup_failed, translated(ready.error))
          end
          return
        end

        apply_confirmed_tool_dispatch_preparation_on_event_loop(
          operation,
          ready.result,
          state
        )
      rescue => error
        state&.invocation&.event_sink&.post(:tool_setup_failed, translated(error))
      end

      def apply_confirmed_provider_dispatch_preparation_on_event_loop(
        operation,
        result,
        state
      )
        event_loop = Phronomy::Runtime.instance.event_loop
        if result.runtime_projection
          Phronomy::Agent::ExecutionRegistry.for(event_loop).replace_agent_execution(
            operation.execution_id,
            execution: result.execution,
            runtime_projection: result.runtime_projection
          )
        else
          Phronomy::Agent::ExecutionRegistry.for(event_loop).replace_agent_execution(
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
      end

      def apply_confirmed_tool_dispatch_preparation_on_event_loop(
        operation,
        result,
        state
      )
        event_loop = Phronomy::Runtime.instance.event_loop
        Phronomy::Agent::ExecutionRegistry.for(event_loop).replace_agent_execution(
          operation.execution_id,
          execution: result.execution
        )
        state.invocation.acknowledge_runtime_snapshot(operation.runtime_snapshot)
        Agent::AgentInvocationSessionBuilder.start_prepared_tool_dispatch(
          runtime: Phronomy::Runtime.instance,
          event_sink: state.invocation.event_sink,
          invocation: state.invocation
        )
      end

      def apply_provider_dispatch_preparation_reconciliation_on_event_loop(ready)
        command = ready.command
        operation = command.operation
        state = authoritative_state_for_operation(
          execution_id: operation.execution_id,
          fsm_session_id: operation.fsm_session_id,
          expected_execution_revision: operation.expected_execution_revision,
          expected_fsm_state: :calling_llm
        )
        return unless state

        if ready.error
          mark_barrier_recovery_required(operation, ready.error)
          return
        end

        case ready.result.disposition
        when :committed
          apply_confirmed_provider_dispatch_preparation_on_event_loop(
            operation,
            ready.result.preparation_result,
            state
          )
        when :not_committed
          state.invocation.event_sink.post(
            :llm_setup_failed,
            translated(command.original_error)
          )
        when :conflict
          mark_barrier_recovery_required(operation, command.original_error)
        else
          raise Phronomy::Error,
            "unknown Provider dispatch reconciliation disposition: " \
            "#{ready.result.disposition.inspect}"
        end
      rescue => error
        mark_barrier_recovery_required(operation, error)
      end

      def apply_tool_dispatch_preparation_reconciliation_on_event_loop(ready)
        command = ready.command
        operation = command.operation
        state = authoritative_state_for_operation(
          execution_id: operation.execution_id,
          fsm_session_id: operation.fsm_session_id,
          expected_execution_revision: operation.expected_execution_revision,
          expected_fsm_state: :dispatching_tools
        )
        return unless state

        if ready.error
          mark_barrier_recovery_required(operation, ready.error)
          return
        end

        case ready.result.disposition
        when :committed
          apply_confirmed_tool_dispatch_preparation_on_event_loop(
            operation,
            ready.result.preparation_result,
            state
          )
        when :not_committed
          state.invocation.event_sink.post(
            :tool_setup_failed,
            translated(command.original_error)
          )
        when :conflict
          mark_barrier_recovery_required(operation, command.original_error)
        else
          raise Phronomy::Error,
            "unknown Tool dispatch reconciliation disposition: " \
            "#{ready.result.disposition.inspect}"
        end
      rescue => error
        mark_barrier_recovery_required(operation, error)
        # simplecov:enable
      end

      def mark_barrier_recovery_required(operation, error)
        event_loop = Phronomy::Runtime.instance.event_loop
        Phronomy::Agent::ExecutionRegistry.for(event_loop).mark_agent_execution_admission(
          @agent.agent_id,
          execution_id: operation.execution_id,
          state: :recovery_required
        )
        Phronomy.configuration.logger&.warn(
          "[Phronomy] causal durable barrier requires recovery for " \
          "#{operation.execution_id}: #{error.class}: #{error.message}"
        )
      end

      # ----------------------------------------------------------------------
      # Approval resume
      # ----------------------------------------------------------------------

      def begin_resume_on_event_loop(request)
        runtime = Phronomy::Runtime.instance
        event_loop = runtime.event_loop
        state = Phronomy::Agent::ExecutionRegistry.for(event_loop).agent_execution_state(request.execution_id)
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

        operation = capture_approval_resume(state, request)
        resume_transition_started = false
        submitted = false
        Phronomy::Agent::ExecutionRegistry.for(event_loop).mark_agent_execution_admission(
          @agent.agent_id,
          execution_id: state.execution_id,
          state: :resuming
        )
        resume_transition_started = true
        task = Phronomy::Storage::AsyncClient.submit(pool: runtime.offload) do
          @approval_resume_commit.commit(operation)
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
          Phronomy::Agent::ExecutionRegistry.for(event_loop).mark_agent_execution_admission(
            @agent.agent_id,
            execution_id: state.execution_id,
            state: submitted ? :recovery_required : :suspended
          )
        end
        fail_task(request.result_task, translated(error))
        raise unless resume_transition_started
      end

      def capture_approval_resume(state, request)
        snapshot = if state.invocation
          Phronomy::Values::Immutable.copy(
            ExecutionMetadata.build_tool_batch_snapshot(state.invocation)
          )
        end
        ResumeCommitCommand.new(
          execution_id: state.execution_id,
          expected_execution_revision: state.execution.execution_revision,
          root: @agent.agent_root,
          execution: state.execution,
          approval_request_id: request.approval_request_id,
          approved: request.approved,
          tool_batch_snapshot: snapshot
        )
      end

      def apply_resume_commit_on_event_loop(ready)
        request = ready.request
        operation = ready.operation
        event_loop = Phronomy::Runtime.instance.event_loop
        state = Phronomy::Agent::ExecutionRegistry.for(event_loop).agent_execution_state(operation.execution_id)
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
          Phronomy::Agent::ExecutionRegistry.for(event_loop).mark_agent_execution_admission(
            @agent.agent_id,
            execution_id: operation.execution_id,
            state: :recovery_required
          )
          fail_task(request.result_task, translated(ready.error))
          return
        end

        install_resumed_execution_on_event_loop(ready, event_loop)
        observe_resumed_execution(ready, state)
        execution_session_runner(Phronomy::Runtime.instance).resume_approval(
          state.invocation, request.result_task,
          approved: request.approved, config: request.config
        )
      rescue => error
        state = Phronomy::Agent::ExecutionRegistry.for(event_loop).agent_execution_state(operation.execution_id) if event_loop&.current?
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

      def install_resumed_execution_on_event_loop(ready, event_loop)
        request = ready.request
        operation = ready.operation
        apply_agent_live_state(root: ready.result.root, appended_records: [])
        Phronomy::Agent::ExecutionRegistry.for(event_loop).mark_agent_execution_admission(
          @agent.agent_id,
          execution_id: operation.execution_id,
          state: :executing
        )
        Phronomy::Agent::ExecutionRegistry.for(event_loop).replace_agent_execution(
          operation.execution_id,
          execution: ready.result.execution
        )
        Phronomy::Agent::ExecutionRegistry.for(event_loop).register_agent_completion_waiter(
          operation.execution_id,
          request.result_task
        )
      end

      def observe_resumed_execution(ready, state)
        request = ready.request
        operation = ready.operation
        trace_config = state.invocation ?
          state.invocation.config.merge(request.config) : request.config
        trace_mode = state.invocation&.mode ||
          (
            ready.result.execution.metadata[
              ExecutionMetadata::INVOCATION_MODE_KEY
            ] || "invoke"
          ).to_sym
        Phronomy::Tracing::Automatic.observe_task(
          request.result_task,
          "agent.execution",
          agent_id: @agent.agent_id,
          execution_id: operation.execution_id,
          mode: trace_mode,
          **@agent.send(:_build_caller_meta, trace_config)
        )
      end

      # Recovery chooses a semantic continuation after resolving saved facts.
      # Execution owns validation, admission, live installation and FSM entry.
      def recover_preparation_on_event_loop(command)
        state = recovered_execution_state!(command)
        unless state.execution.status == :preparing && state.execution.phase.to_sym == :preparing
          raise Phronomy::ExecutionRehydrationRequiredError,
            "initial preparation continuation requires a :preparing execution"
        end
        ExecutionRegistry.for(Phronomy::Runtime.instance.event_loop).mark_agent_execution_admission(
          @agent.agent_id, execution_id: state.execution_id, state: :executing
        )
        start_initial_preparation_recovery_on_event_loop(
          state.execution, command.result_task, load_completion: command.load_completion
        )
      rescue => error
        fail_task(command.result_task, translated(error))
        command.load_completion.fail(translated(error))
      end

      def continue_recovered_on_event_loop(command)
        runtime = Phronomy::Runtime.instance
        registry = ExecutionRegistry.for(runtime.event_loop)
        state = recovered_execution_state!(command)
        validate_recovered_continuation!(state.execution, command.continuation)
        invocation = command.invocation
        unless invocation && invocation.agent.equal?(@agent) &&
            invocation.execution_id.to_s == state.execution_id.to_s
          raise Phronomy::ExecutionRehydrationRequiredError,
            "recovered invocation does not belong to execution #{state.execution_id}"
        end
        if command.continuation == :failed_terminal && !command.error.is_a?(Exception)
          raise Phronomy::ExecutionRehydrationRequiredError,
            "failed recovery continuation requires a failure"
        end

        state = registry.replace_agent_execution(state.execution_id,
          runtime_projection: command.runtime_projection, invocation: invocation, fsm_session_id: nil)
        if command.continuation == :failed_terminal
          begin_terminal_commit_on_event_loop(state, command.result_task, invocation,
            command.error, fsm_session_id: nil)
          return
        end

        registry.mark_agent_execution_admission(@agent.agent_id,
          execution_id: state.execution_id, state: :executing)
        registry.register_agent_completion_waiter(state.execution_id, command.result_task)
        runner = execution_session_runner(runtime)
        case command.continuation
        when :approval_rejection
          runner.resume_approval(invocation, command.result_task, approved: false, config: {})
        when :framework_tools
          runner.resume_framework_tools(invocation, command.result_task)
        when :framework_calls, :output
          runner.resume(invocation, command.result_task,
            resume_event: :llm_completed, resume_phase: :calling_llm)
        when :followup
          runner.resume(invocation, command.result_task,
            resume_event: :state_completed, resume_phase: :recording_tool_results)
        end
      end

      def recovered_execution_state!(command)
        state = ExecutionRegistry.for(Phronomy::Runtime.instance.event_loop).agent_execution_state(command.execution_id)
        unless command.coordinator.equal?(self) && state && state.agent.equal?(@agent) &&
            state.coordinator.equal?(self) && state.execution.active? &&
            state.execution.execution_revision == command.expected_execution_revision &&
            state.fsm_session_id.nil?
          raise Phronomy::ExecutionRehydrationRequiredError,
            "stale recovered execution continuation for #{command.execution_id}"
        end
        state
      end

      def execution_session_runner(runtime)
        ExecutionSessionRunner.new(runtime: runtime, on_complete: ->(**result) {
          deliver_on_event_loop(SessionFinishedCommand.new(coordinator: self, **result))
        })
      end

      def validate_recovered_continuation!(execution, continuation)
        phase = execution.phase.to_sym
        valid = case continuation
        when :framework_tools
          %i[dispatching_tools resuming recovery_tools].include?(phase) && execution.status != :suspended
        when :framework_calls
          %i[recovery_provider_completed recovery_tools_completed].include?(phase) &&
            execution.metadata["framework_calls_pending"]
        when :output
          phase == :recovery_provider_completed && !execution.metadata["framework_calls_pending"]
        when :followup
          phase == :recovery_tools_completed && !execution.metadata["framework_calls_pending"]
        when :failed_terminal
          phase == :recovery_resolved_failed
        when :approval_rejection
          approval = execution.approval_request
          phase == :resuming && !(approval && (approval["approved"] || approval[:approved]))
        end
        return if valid

        raise Phronomy::ExecutionRehydrationRequiredError,
          "invalid recovered continuation #{continuation.inspect} for #{phase.inspect}"
      end

      # ----------------------------------------------------------------------
      # Terminal durable barrier
      # ----------------------------------------------------------------------

      def finish_on_event_loop(execution_id, result_task, invocation, error, fsm_session_id:)
        event_loop = Phronomy::Runtime.instance.event_loop
        assert_event_loop!(event_loop)
        state = Phronomy::Agent::ExecutionRegistry.for(event_loop).agent_execution_state(execution_id)
        return fail_task(result_task, runtime_rejected_error(:terminal)) unless state

        unless state.agent.equal?(@agent) && state.coordinator.equal?(self) &&
            state.fsm_session_id.to_s == fsm_session_id.to_s &&
            state.invocation.equal?(invocation)
          return fail_task(
            result_task,
            Phronomy::Error.new("stale Agent terminal callback for #{execution_id}")
          )
        end

        terminal_error = error || invocation&.error
        unless Phronomy::Agent::ExecutionRegistry.for(event_loop).agent_execution_quiescent?(execution_id)
          wait_state = quiescence_sensitive_terminal_error?(terminal_error) ?
            :cancelling : :terminalizing
          Phronomy::Agent::ExecutionRegistry.for(event_loop).mark_agent_execution_admission(
            @agent.agent_id,
            execution_id: execution_id,
            state: wait_state
          )
          Phronomy::Agent::ExecutionRegistry.for(event_loop).defer_agent_terminal_until_quiescent(
            execution_id,
            DeferredTerminalCommand.new(
              coordinator: self,
              execution_id: execution_id.to_s.freeze,
              result_task: result_task,
              invocation: invocation,
              source_error: error,
              fsm_session_id: fsm_session_id.to_s.freeze
            )
          )
          return
        end

        begin_terminal_commit_on_event_loop(
          state,
          result_task,
          invocation,
          error,
          fsm_session_id: fsm_session_id
        )
      end

      def resume_deferred_terminal_on_event_loop(command)
        event_loop = Phronomy::Runtime.instance.event_loop
        state = Phronomy::Agent::ExecutionRegistry.for(event_loop).agent_execution_state(command.execution_id)
        unless state && state.agent.equal?(@agent) &&
            state.fsm_session_id.to_s == command.fsm_session_id.to_s &&
            state.invocation.equal?(command.invocation)
          Phronomy.configuration.logger&.warn(
            "[Phronomy] Dropped stale deferred terminal for #{command.execution_id}"
          )
          return
        end

        unless Phronomy::Agent::ExecutionRegistry.for(event_loop).agent_execution_quiescent?(command.execution_id)
          raise Phronomy::Error,
            "deferred terminal resumed before quiescence for #{command.execution_id}"
        end

        begin_terminal_commit_on_event_loop(
          state,
          command.result_task,
          command.invocation,
          command.source_error,
          fsm_session_id: command.fsm_session_id
        )
      end

      def quiescence_sensitive_terminal_error?(error)
        error.is_a?(Phronomy::CancellationError) ||
          error.is_a?(Phronomy::TimeoutError)
      end

      def begin_terminal_commit_on_event_loop(
        state,
        result_task,
        invocation,
        source_error,
        fsm_session_id:
      )
        if invocation&.phase == :suspended
          snapshot = ExecutionMetadata.build_tool_batch_snapshot(invocation)
          staged_execution = ExecutionMetadata.with_values(
            state.execution,
            ExecutionMetadata::TOOL_BATCH_METADATA_KEY => snapshot
          )
          state = state.class.new(
            **state.to_h.merge(execution: staged_execution)
          )
        end

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

      def build_outcome_committer
        ExecutionOutcomeCommitter.new(agent: @agent, persistence: @agent.persistence)
      end

      def submit_terminal_operation(operation, delivery)
        runtime = Phronomy::Runtime.instance
        event_loop = runtime.event_loop
        terminal_transition_started = false
        Phronomy::Agent::ExecutionRegistry.for(event_loop).mark_agent_execution_admission(
          @agent.agent_id,
          execution_id: operation.execution_id,
          state: :terminalizing
        )
        terminal_transition_started = true
        Phronomy::Agent::ExecutionRegistry.for(event_loop).register_agent_completion_waiter(
          operation.execution_id,
          delivery.result_task
        )
        task = Phronomy::Storage::AsyncClient.submit(pool: runtime.offload) do
          # Only the operation-specific immutable durable snapshot crosses the
          # worker boundary. TaskResult/listener delivery state stays outside it.
          @outcome_committer.commit_outcome(operation)
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
          Phronomy::Agent::ExecutionRegistry.for(event_loop).mark_agent_execution_admission(
            @agent.agent_id,
            execution_id: operation.execution_id,
            state: :recovery_required
          )
          Phronomy.configuration.logger&.warn(
            "[Phronomy] Agent terminal transition requires recovery for " \
            "#{operation.execution_id}: #{error.class}: #{error.message}"
          )
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
          source_error: source_error,
          cancel_requested: invocation&.config&.fetch(:cancellation_token, nil)&.cancelled? || false
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
          tool_call_id: request.tool_call_id&.to_s&.freeze,
          policy: Phronomy::Values::Immutable.copy(request.handoff.policy.to_h)
        )
      end

      def empty_runtime_snapshot
        {llm_results: [].freeze, runtime_events: [].freeze, active_call: nil}.freeze
      end

      def apply_terminal_commit_on_event_loop(ready)
        operation = ready.operation
        delivery = ready.delivery
        event_loop = Phronomy::Runtime.instance.event_loop
        state = Phronomy::Agent::ExecutionRegistry.for(event_loop).agent_execution_state(operation.execution_id)

        if operation.state_required
          unless state && state.agent.equal?(@agent) &&
              state.execution.execution_revision == operation.expected_execution_revision &&
              state.fsm_session_id.to_s == operation.fsm_session_id.to_s
            Phronomy.configuration.logger&.warn(
              "[Phronomy] Dropped stale Agent terminal result for #{operation.execution_id}"
            )
            return
          end
        end

        if ready.error
          handle_terminal_commit_error_on_event_loop(ready, state, event_loop)
          return
        end

        apply_terminal_outcome_state_on_event_loop(ready, state, event_loop)
        outcome = ready.outcome
        case outcome.type
        when :coordination_wait
          release_coordination_wait_on_event_loop(ready, state, event_loop)
        when :suspended
          suspend_execution_on_event_loop(ready, state, event_loop)
        when :completed
          deliver_completed_execution_on_event_loop(ready, state, event_loop)
        when :handed_off
          deliver_handoff_on_event_loop(ready, state, event_loop)
        when :failed
          deliver_failed_execution_on_event_loop(ready, state, event_loop)
        else
          fail_task(
            delivery.result_task,
            Phronomy::Error.new("unknown terminal outcome: #{outcome.type.inspect}")
          )
        end
      end

      def handle_terminal_commit_error_on_event_loop(ready, state, event_loop)
        operation = ready.operation
        delivery = ready.delivery
        if operation.execution.metadata["coordination"] || operation.execution.metadata["multi_agent_coordination_ref"]
          release_terminal_ownership(event_loop, operation.execution_id, state)
          Phronomy::Agent::ExecutionRegistry.for(event_loop).take_agent_completion_waiters(operation.execution_id, fallback: delivery.result_task).each do |task|
            task.fail(ready.error)
          end
          return
        end
        Phronomy::Agent::ExecutionRegistry.for(event_loop).mark_agent_execution_admission(
          @agent.agent_id,
          execution_id: operation.execution_id,
          state: :recovery_required
        )
        Phronomy.configuration.logger&.warn(
          "[Phronomy] Agent terminal durable outcome requires recovery for " \
          "#{operation.execution_id}: #{ready.error.class}: #{ready.error.message}"
        )
      end

      def apply_terminal_outcome_state_on_event_loop(ready, state, event_loop)
        operation = ready.operation
        outcome = ready.outcome
        apply_agent_live_state(
          root: outcome.root,
          appended_records: outcome.appended_records
        )
        if state
          state.invocation&.acknowledge_runtime_snapshot(operation.runtime_snapshot)
          Phronomy::Agent::ExecutionRegistry.for(event_loop).replace_agent_execution(
            operation.execution_id,
            execution: outcome.execution,
            fsm_session_id: (outcome.type == :suspended) ? nil : state.fsm_session_id
          )
        end
      end

      def release_coordination_wait_on_event_loop(ready, state, event_loop)
        operation = ready.operation
        delivery = ready.delivery
        outcome = ready.outcome
        release_terminal_ownership(event_loop, operation.execution_id, state)
        Phronomy::Agent::ExecutionRegistry.for(event_loop).take_agent_completion_waiters(operation.execution_id, fallback: delivery.result_task).each { |task| task.fail(outcome.error) }
      end

      def suspend_execution_on_event_loop(ready, state, event_loop)
        operation = ready.operation
        delivery = ready.delivery
        outcome = ready.outcome
        Phronomy::Agent::ExecutionRegistry.for(event_loop).mark_agent_execution_admission(
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
        report_nonterminal_callback_error(
          callback_error,
          :approval_required,
          outcome.result
        )
        Array(state&.invocation&.config&.fetch(:phronomy_exact_observers, [])).each do |task|
          task.fail(Phronomy::ExecutionRehydrationRequiredError.new("Execution #{operation.execution_id} requires approval"))
        end
      end

      def deliver_completed_execution_on_event_loop(ready, state, event_loop)
        operation = ready.operation
        delivery = ready.delivery
        outcome = ready.outcome
        release_terminal_ownership(event_loop, operation.execution_id, state)
        callback_error = deliver_terminal(delivery.application_listener, :done, outcome.result)
        settle_execution_waiters(
          event_loop, operation.execution_id, delivery.result_task,
          callback_error, :done, outcome.result
        )
      end

      def deliver_handoff_on_event_loop(ready, state, event_loop)
        operation = ready.operation
        delivery = ready.delivery
        outcome = ready.outcome
        release_terminal_ownership(event_loop, operation.execution_id, state)
        result = outcome.result.merge(
          handoff_request: delivery.handoff_request,
          _phronomy_handoff_manifest: delivery.handoff_manifest
        ).freeze
        callback_error = deliver_terminal(delivery.application_listener, :handoff, result)
        settle_execution_waiters(
          event_loop, operation.execution_id, delivery.result_task,
          callback_error, :handoff, result
        )
      end

      def deliver_failed_execution_on_event_loop(ready, state, event_loop)
        operation = ready.operation
        delivery = ready.delivery
        outcome = ready.outcome
        release_terminal_ownership(event_loop, operation.execution_id, state)
        type = terminal_event_type(outcome.error)
        callback_error = deliver_terminal(
          delivery.application_listener,
          type,
          error: outcome.error
        )
        settle_execution_waiters(
          event_loop, operation.execution_id, delivery.result_task,
          callback_error, type, nil, outcome.error
        )
      end

      def release_terminal_ownership(event_loop, execution_id, state)
        registry = Phronomy::Agent::ExecutionRegistry.for(event_loop)
        registry.release_agent_execution(execution_id) if state
        registry.release_agent_execution_admission(@agent.agent_id, execution_id: execution_id)
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
        state = Phronomy::Agent::ExecutionRegistry.for(event_loop).agent_execution_state(execution_id)
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

      def settle_execution_waiters(
        event_loop, execution_id, fallback_task, callback_error, event_type,
        result, execution_error = nil
      )
        waiters = Phronomy::Agent::ExecutionRegistry.for(event_loop).take_agent_completion_waiters(
          execution_id,
          fallback: fallback_task
        )
        waiters.each do |task|
          settle_after_terminal(
            task, callback_error, event_type, result, execution_error
          )
        end
      end

      def report_nonterminal_callback_error(callback_error, event_type, result)
        return unless callback_error

        @agent.send(
          :_report_stream_callback_error,
          callback_error,
          event: StreamEvent.new(type: event_type, payload: result),
          execution_id: result&.fetch(:execution_id, nil),
          callback_error_policy: Phronomy.configuration.stream_callback_error_policy
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
        if execution_error
          if execution_error.is_a?(Phronomy::CancellationError)
            result_task.cancel!(execution_error)
          else
            fail_task(result_task, execution_error)
          end
        else
          complete_task(result_task, result)
        end
      end

      def terminal_event_type(error)
        return :timeout if error.is_a?(Phronomy::TimeoutError)
        return :cancelled if error.is_a?(Phronomy::CancellationError)

        :error
      end

      def post_control(runtime, command)
        admission = command.is_a?(StartCommand) || command.is_a?(ResumeCommand)
        completion = case command
        when StartCommand, ResumeCommand then command.result_task
        when InitialPreparationReady, ResumeCommitReady then command.request.result_task
        when InitialPreparationRecoveryReady then command.load_completion
        when TerminalCommitReady then command.delivery.result_task
        when DeferredTerminalCommand then command.result_task
        end
        ExecutionRegistry.for(runtime.event_loop).post(command,
          admission: admission, completion: completion)
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
