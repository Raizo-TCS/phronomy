# frozen_string_literal: true

require "securerandom"

module Phronomy
  # Execution boundary for compiled Workflows.
  #
  # WorkflowRunner separates three identities/responsibilities:
  # - application session_id remains caller/tracing metadata;
  # - workflow_instance_id identifies durable Workflow state;
  # - each concrete FSMSession owns a runtime-only fsm_session_id;
  # - Runtime admission uses a separate opaque owner token.
  #
  # Workflow persistence is synchronous at the repository contract but is always
  # invoked through Runtime's OffloadPool. Durable terminal save results return
  # to the same FSMSession before that session becomes halted/completed.
  # @api private
  class WorkflowRunner
    include Phronomy::Runnable

    FINISH = :__end__

    Execution = Data.define(
      :context,
      :workflow_instance_id,
      :owner_token,
      :recursion_limit,
      :repository,
      :persist,
      :expected_revision
    )

    # API/callback -> EventLoop control messages.
    StartCommand = Data.define(
      :runner,
      :input,
      :config,
      :stable_observer,
      :result_task,
      :workflow_instance_id,
      :owner_token,
      :explicit_workflow_instance_id
    )
    ResumeCommand = Data.define(
      :runner,
      :state,
      :input,
      :event_name,
      :current_phase,
      :result_task,
      :workflow_instance_id,
      :owner_token
    )

    # EventLoop -> Offload operation-specific immutable/value snapshots.
    WorkflowLoadCommand = Data.define(:repository, :workflow_instance_id)
    WorkflowTerminalPersistenceCommand = Data.define(
      :repository,
      :workflow_instance_id,
      :expected_revision,
      :snapshot
    )

    # Offload -> EventLoop/FSMSession operation results.
    WorkflowLoadResult = Data.define(:repository, :snapshot, :revision)
    WorkflowTerminalPersistenceResult = Data.define(:outcome, :revision, :error)

    StartLoadReady = Data.define(:runner, :request, :result, :error)
    ResumeLoadReady = Data.define(:runner, :request, :result, :error)

    def initialize(
      state_class:,
      entry_actions:,
      declared_states:,
      auto_transitions:,
      external_events:,
      entry_point:,
      exit_actions: {},
      wait_state_names: [],
      persistence: nil
    )
      @state_class = state_class
      @entry_actions = entry_actions
      @declared_states = declared_states
      @auto_state_set = auto_transitions.each_with_object({}) do |transition, set|
        set[transition[:from]] = true
      end
      @external_events = external_events
      @entry_point = entry_point
      @wait_state_names = wait_state_names
      @persistence = persistence
      @phase_machine_class = Workflow::PhaseMachineBuilder.new(
        entry_point: @entry_point,
        declared_states: @declared_states,
        wait_state_names: @wait_state_names,
        external_events: @external_events,
        entry_actions: @entry_actions,
        auto_transitions: auto_transitions,
        exit_actions: exit_actions
      ).build
    end

    def invoke(input, config: {})
      ensure_blocking_call_allowed!(:invoke, :invoke_async)
      start_new_execution(input, config).wait_result
    end

    def invoke_deferred(input, config: {})
      start_new_execution(input, config)
    end

    def stream(input, config: {}, &observer)
      ensure_blocking_call_allowed!(:stream, :invoke_async)
      raise ArgumentError, "stream requires a block" unless observer

      start_new_execution(input, config, stable_observer: observer).wait_result
    end

    def resume(state:, input: nil)
      send_event(state: state, event: :resume, input: input)
    end

    def send_event(state:, event:, input: nil)
      ensure_blocking_call_allowed!(:send_event, :signal)
      current_phase = state.phase.to_sym
      event_name = resolve_resume_event(current_phase, event)
      workflow_instance_id = state.workflow_instance_id
      unless workflow_instance_id
        raise ArgumentError, "Halted WorkflowContext has no workflow_instance_id"
      end

      start_resume_execution(
        state,
        input: input,
        event_name: event_name,
        current_phase: current_phase
      ).wait_result
    end

    # Posts an application-defined event to the currently live Workflow owner.
    # EventLoop resolves workflow_instance_id to the current concrete
    # fsm_session_id. The opaque admission owner token is deliberately not a
    # routing identity and is not exposed here.
    def signal(workflow_instance_id:, event:, payload: nil)
      raise ArgumentError, "workflow_instance_id is required" if workflow_instance_id.nil?

      event_name = event.to_sym
      unless @external_events.key?(event_name)
        raise ArgumentError,
          "Unknown event #{event_name.inspect}. " \
          "Valid events: #{@external_events.keys.inspect}"
      end

      Phronomy::Runtime.instance.event_loop.post_to_workflow(
        workflow_instance_id: workflow_instance_id,
        event: event_name,
        payload: payload
      )
    end

    # Every Workflow control message is delivered by EventLoop. Admission,
    # hydration apply, FSMSession creation/binding, and terminal live-state
    # progression therefore remain EventLoop-owned.
    # @api private
    def deliver_on_event_loop(command)
      event_loop = Phronomy::Runtime.instance.event_loop
      assert_event_loop!(event_loop)

      case command
      when StartCommand
        begin_start_on_event_loop(command)
      when ResumeCommand
        begin_resume_on_event_loop(command)
      when StartLoadReady
        apply_start_load_on_event_loop(command)
      when ResumeLoadReady
        apply_resume_load_on_event_loop(command)
      else
        raise Phronomy::Error, "unknown Workflow control command: #{command.class}"
      end
    end

    private

    def workflow_trace_metadata(config)
      metadata = {}
      metadata[:user_id] = config[:user_id] if config[:user_id]
      metadata[:session_id] = config[:session_id] if config[:session_id]
      if (invocation_context = config[:invocation_context])
        metadata[:task_id] = invocation_context.task_id if invocation_context.task_id
        if invocation_context.parent_task_id
          metadata[:parent_task_id] = invocation_context.parent_task_id
        end
      end
      metadata
    end

    # CG-01 is a clean break. Reject the removed Workflow config key instead of
    # silently generating a new Workflow identity and branching durable history.
    # This is a migration error path, not a compatibility alias.
    def reject_legacy_workflow_identity_key!(config)
      return unless config.key?(:thread_id) || config.key?("thread_id")

      raise ArgumentError,
        "Workflow config key :thread_id was removed; use :workflow_instance_id"
    end

    def ensure_blocking_call_allowed!(method_name, async_alternative)
      return unless Phronomy::Runtime.instance.event_loop.current?

      raise Phronomy::Error,
        "Cannot call Workflow##{method_name} from the EventLoop thread. " \
        "Use #{async_alternative} instead."
    end

    def start_new_execution(input, config, stable_observer: nil)
      reject_legacy_workflow_identity_key!(config)
      runtime = Phronomy::Runtime.instance
      result_task = Phronomy::Task.deferred(name: "workflow:preparing")
      explicit_workflow_instance_id = !config[:workflow_instance_id].nil?
      workflow_instance_id = (config[:workflow_instance_id] || SecureRandom.uuid).to_s.freeze
      Phronomy::Tracing::Automatic.observe_task(
        result_task,
        "workflow.execution",
        input: input,
        workflow_instance_id: workflow_instance_id,
        mode: stable_observer ? :stream : :invoke,
        **workflow_trace_metadata(config)
      )
      command = StartCommand.new(
        runner: self,
        input: input,
        config: config.dup.freeze,
        stable_observer: stable_observer,
        result_task: result_task,
        workflow_instance_id: workflow_instance_id,
        owner_token: Object.new.freeze,
        explicit_workflow_instance_id: explicit_workflow_instance_id
      )
      fail_task(result_task, runtime_rejected_error(:start)) unless post_control(runtime, command)
      result_task
    rescue => error
      fail_task(result_task, error) if defined?(result_task) && result_task
      result_task || failed_task("workflow:preparation", error)
    end

    def start_resume_execution(state, input:, event_name:, current_phase:)
      runtime = Phronomy::Runtime.instance
      workflow_instance_id = state.workflow_instance_id.to_s.freeze
      result_task = Phronomy::Task.deferred(name: "workflow-resume:#{workflow_instance_id}")
      Phronomy::Tracing::Automatic.observe_task(
        result_task,
        "workflow.execution",
        input: input,
        workflow_instance_id: workflow_instance_id,
        mode: :resume,
        event: event_name
      )
      command = ResumeCommand.new(
        runner: self,
        state: state,
        input: input,
        event_name: event_name.to_sym,
        current_phase: current_phase.to_sym,
        result_task: result_task,
        workflow_instance_id: workflow_instance_id,
        owner_token: Object.new.freeze
      )
      fail_task(result_task, runtime_rejected_error(:resume)) unless post_control(runtime, command)
      result_task
    rescue => error
      fail_task(result_task, error) if defined?(result_task) && result_task
      result_task || failed_task("workflow:resume-preparation", error)
    end

    def begin_start_on_event_loop(request)
      runtime = Phronomy::Runtime.instance
      event_loop = runtime.event_loop
      admitted = false
      event_loop.admit_workflow(
        request.workflow_instance_id,
        owner_token: request.owner_token
      )
      admitted = true

      recursion_limit = request.config.fetch(
        :recursion_limit,
        Phronomy.configuration.recursion_limit
      )
      repository = configured_repository
      persist = request.explicit_workflow_instance_id && !repository.nil?

      unless persist
        execution = build_new_execution(
          request.input,
          workflow_instance_id: request.workflow_instance_id,
          owner_token: request.owner_token,
          recursion_limit: recursion_limit,
          repository: repository,
          persist: false,
          loaded_snapshot: nil,
          expected_revision: nil
        )
        register_execution(
          execution,
          request.result_task,
          stable_observer: request.stable_observer
        )
        return
      end

      submit_workflow_load(
        runtime,
        repository,
        request.workflow_instance_id,
        StartLoadReady,
        request
      )
    rescue => error
      if admitted
        event_loop.release_workflow(
          request.workflow_instance_id,
          owner_token: request.owner_token
        )
      end
      fail_task(request.result_task, error)
    end

    def begin_resume_on_event_loop(request)
      runtime = Phronomy::Runtime.instance
      event_loop = runtime.event_loop
      admitted = false
      event_loop.admit_workflow(
        request.workflow_instance_id,
        owner_token: request.owner_token
      )
      admitted = true

      repository = configured_repository
      unless repository
        context = request.input ? request.state.merge(request.input) : request.state
        execution = Execution.new(
          context: context,
          workflow_instance_id: request.workflow_instance_id,
          owner_token: request.owner_token,
          recursion_limit: Phronomy.configuration.recursion_limit,
          repository: nil,
          persist: false,
          expected_revision: nil
        )
        register_execution(
          execution,
          request.result_task,
          resume_event: request.event_name,
          resume_phase: request.current_phase
        )
        return
      end

      submit_workflow_load(
        runtime,
        repository,
        request.workflow_instance_id,
        ResumeLoadReady,
        request
      )
    rescue => error
      if admitted
        event_loop.release_workflow(
          request.workflow_instance_id,
          owner_token: request.owner_token
        )
      end
      fail_task(request.result_task, error)
    end

    def submit_workflow_load(runtime, repository, workflow_instance_id, ready_class, request)
      operation = WorkflowLoadCommand.new(
        repository: repository,
        workflow_instance_id: workflow_instance_id.to_s.freeze
      )
      task = runtime.offload.submit(on_full: :raise) do
        record = operation.repository.load(operation.workflow_instance_id)
        WorkflowLoadResult.new(
          repository: operation.repository,
          snapshot: deep_immutable_copy(record_value(record, :snapshot)),
          revision: record_value(record, :revision)
        )
      end
      task.on_complete do |result, error|
        ready = ready_class.new(
          runner: self,
          request: request,
          result: result,
          error: error
        )
        fail_task(request.result_task, runtime_rejected_error(:load_result)) unless
          post_control(runtime, ready)
      end
      nil
    end

    def apply_start_load_on_event_loop(ready)
      request = ready.request
      if ready.error
        release_and_fail(request, ready.error)
        return
      end

      recursion_limit = request.config.fetch(
        :recursion_limit,
        Phronomy.configuration.recursion_limit
      )
      execution = build_new_execution(
        request.input,
        workflow_instance_id: request.workflow_instance_id,
        owner_token: request.owner_token,
        recursion_limit: recursion_limit,
        repository: ready.result.repository,
        persist: true,
        loaded_snapshot: ready.result.snapshot,
        expected_revision: ready.result.revision
      )
      register_execution(
        execution,
        request.result_task,
        stable_observer: request.stable_observer
      )
    rescue => error
      release_and_fail(request, error)
    end

    def apply_resume_load_on_event_loop(ready)
      request = ready.request
      if ready.error
        release_and_fail(request, ready.error)
        return
      end

      expected_revision = validate_resume_snapshot!(
        request.state,
        ready.result.snapshot,
        ready.result.revision
      )
      context = request.input ? request.state.merge(request.input) : request.state
      execution = Execution.new(
        context: context,
        workflow_instance_id: request.workflow_instance_id,
        owner_token: request.owner_token,
        recursion_limit: Phronomy.configuration.recursion_limit,
        repository: ready.result.repository,
        persist: true,
        expected_revision: expected_revision
      )
      register_execution(
        execution,
        request.result_task,
        resume_event: request.event_name,
        resume_phase: request.current_phase
      )
    rescue => error
      release_and_fail(request, error)
    end

    def build_new_execution(
      input,
      workflow_instance_id:,
      owner_token:,
      recursion_limit:,
      repository:,
      persist:,
      loaded_snapshot:,
      expected_revision:
    )
      stored_fields = loaded_snapshot &&
        (loaded_snapshot[:fields] || loaded_snapshot["fields"])
      initial_fields = if stored_fields
        stored_fields
          .transform_keys(&:to_sym)
          .merge(input.transform_keys(&:to_sym))
      else
        input
      end

      context = @state_class.new(**initial_fields)
      context.set_graph_metadata(workflow_instance_id: workflow_instance_id)

      Execution.new(
        context: context,
        workflow_instance_id: workflow_instance_id,
        owner_token: owner_token,
        recursion_limit: recursion_limit,
        repository: repository,
        persist: persist,
        expected_revision: expected_revision
      )
    end

    def validate_resume_snapshot!(state, durable_snapshot, durable_revision)
      return nil unless durable_snapshot

      normalized_durable = normalize_snapshot(durable_snapshot)
      local_snapshot = normalize_snapshot(snapshot_for(state))
      return durable_revision if normalized_durable == local_snapshot

      raise Phronomy::Persistence::ConflictError,
        "Workflow state changed since the supplied halted context for " \
        "workflow_instance_id #{state.workflow_instance_id.inspect}; explicit reload/reconciliation is required"
    end

    def normalize_snapshot(snapshot)
      snapshot ||= {}
      fields = snapshot[:fields] || snapshot["fields"] || {}
      phase = snapshot[:phase] || snapshot["phase"]
      {
        fields: normalize_workflow_value(fields),
        phase: phase&.to_s
      }
    end

    def normalize_workflow_value(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), result|
          result[key.to_s] = normalize_workflow_value(child)
        end
      when Array
        value.map { |child| normalize_workflow_value(child) }
      when Symbol
        value.to_s
      else
        value
      end
    end

    def deep_immutable_copy(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), result|
          copied_key = key.is_a?(String) ? key.dup.freeze : key
          result[copied_key] = deep_immutable_copy(child)
        end.freeze
      when Array
        value.map { |child| deep_immutable_copy(child) }.freeze
      when String
        value.dup.freeze
      else
        value
      end
    end

    def record_value(record, key)
      return nil unless record
      record.key?(key) ? record[key] : record[key.to_s]
    end

    def configured_repository
      persistence = @persistence || Phronomy.configuration.persistence
      persistence&.workflow_states
    end

    def register_execution(
      execution,
      result_task,
      resume_event: nil,
      resume_phase: nil,
      stable_observer: nil
    )
      runtime = Phronomy::Runtime.instance
      event_loop = runtime.event_loop
      assert_event_loop!(event_loop)
      session = build_session_for(
        execution: execution,
        runtime: runtime,
        resume_event: resume_event,
        resume_phase: resume_phase,
        stable_observer: stable_observer
      )
      event_loop.bind_workflow_session(
        execution.workflow_instance_id,
        owner_token: execution.owner_token,
        fsm_session_id: session.id
      )

      source_task = Phronomy::Task.deferred(name: "workflow-source:#{session.id}")
      source_task.on_complete do |result, error|
        finalize_execution(
          execution: execution,
          result_task: result_task,
          result: result,
          error: error
        )
      end
      event_loop.register(session, completion: source_task)
      result_task
    rescue => error
      if event_loop&.current?
        event_loop&.release_workflow(
          execution.workflow_instance_id,
          owner_token: execution.owner_token
        )
      end
      raise error
    end

    # Called from source_task completion on EventLoop, after the FSMSession has
    # accepted the durable terminal result (when a durable barrier is required).
    def finalize_execution(execution:, result_task:, result:, error:)
      event_loop = Phronomy::Runtime.instance.event_loop
      assert_event_loop!(event_loop)
      event_loop.release_workflow(
        execution.workflow_instance_id,
        owner_token: execution.owner_token
      )
      error ? fail_task(result_task, error) : complete_task(result_task, result)
    end

    def begin_terminal_persistence_on_event_loop(
      execution,
      terminal_type:,
      context:,
      event_sink:
    )
      runtime = Phronomy::Runtime.instance
      event_loop = runtime.event_loop
      assert_event_loop!(event_loop)
      event_loop.mark_workflow_admission(
        execution.workflow_instance_id,
        owner_token: execution.owner_token,
        state: :persisting_terminal
      )

      operation = WorkflowTerminalPersistenceCommand.new(
        repository: execution.repository,
        workflow_instance_id: execution.workflow_instance_id.to_s.freeze,
        expected_revision: execution.expected_revision,
        snapshot: deep_immutable_copy(snapshot_for(context))
      )
      task = runtime.offload.submit(on_full: :raise) do
        revision = operation.repository.save(
          operation.workflow_instance_id,
          expected_revision: operation.expected_revision,
          snapshot: operation.snapshot
        )
        WorkflowTerminalPersistenceResult.new(
          outcome: :success,
          revision: revision,
          error: nil
        )
      rescue Phronomy::Persistence::ConflictError,
        Phronomy::Persistence::NotFoundError,
        Phronomy::Persistence::SerializationError,
        Phronomy::Persistence::UnsupportedBackendError => error
        WorkflowTerminalPersistenceResult.new(
          outcome: :known_failure,
          revision: nil,
          error: error
        )
      rescue => error
        # The Backend SPI does not currently provide a portable commit-outcome
        # classifier for arbitrary storage/transport failures. If non-commit is
        # not guaranteed by the Phronomy error contract, fail closed as F1.
        WorkflowTerminalPersistenceResult.new(
          outcome: :outcome_unknown,
          revision: nil,
          error: error
        )
      end
      task.on_complete do |result, operation_error|
        delivery = if operation_error
          WorkflowTerminalPersistenceResult.new(
            outcome: :outcome_unknown,
            revision: nil,
            error: operation_error
          )
        else
          result
        end
        accepted = event_sink.post(:workflow_terminal_persistence_result, delivery)
        unless accepted
          Phronomy.configuration.logger&.warn(
            "[Phronomy] EventLoop rejected Workflow terminal persistence result " \
            "for #{execution.workflow_instance_id.inspect}"
          )
        end
      end
      terminal_type
    end

    def release_and_fail(request, error)
      event_loop = Phronomy::Runtime.instance.event_loop
      assert_event_loop!(event_loop)
      event_loop.release_workflow(
        request.workflow_instance_id,
        owner_token: request.owner_token
      )
      fail_task(request.result_task, error)
    end

    def snapshot_for(context)
      {
        fields: context.to_h,
        phase: context.phase.to_s
      }
    end

    def build_session_for(
      execution:,
      runtime:,
      resume_event: nil,
      resume_phase: nil,
      stable_observer: nil
    )
      terminal_barrier = if execution.repository && execution.persist
        ->(terminal_type:, context:, event_sink:) {
          begin_terminal_persistence_on_event_loop(
            execution,
            terminal_type: terminal_type,
            context: context,
            event_sink: event_sink
          )
        }
      end

      Phronomy::FSMSession.new(
        context: execution.context,
        context_metadata: {
          workflow_instance_id: execution.workflow_instance_id
        },
        entry_point: @entry_point,
        entry_actions: @entry_actions,
        auto_state_set: @auto_state_set,
        declared_states: @declared_states,
        wait_state_names: @wait_state_names,
        external_events: @external_events,
        phase_machine_class: @phase_machine_class,
        recursion_limit: execution.recursion_limit,
        event_loop: runtime.event_loop,
        resume_event: resume_event,
        resume_phase: resume_phase,
        stable_observer: stable_observer,
        terminal_barrier: terminal_barrier
      )
    end

    def resolve_resume_event(current_phase, event)
      event_name = event.to_sym
      unless event_name == :resume
        unless @external_events.key?(event_name)
          raise ArgumentError,
            "Unknown event #{event_name.inspect}. " \
            "Valid events: #{@external_events.keys.inspect}"
        end
        return event_name
      end

      name, = @external_events.find do |_candidate, transitions|
        Array(transitions).any? do |transition|
          transition[:from] == current_phase
        end
      end
      return name if name

      raise ArgumentError,
        "No external event registered for state #{current_phase.inspect}"
    end

    def post_control(runtime, command)
      runtime.event_loop.post(
        Phronomy::Event.new(
          type: :workflow_control,
          target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
          payload: {command: command}
        )
      )
    end

    def runtime_rejected_error(action)
      Phronomy::RuntimeShutdownError.new(
        "Runtime rejected Workflow #{action} while shutting down"
      )
    end

    def assert_event_loop!(event_loop)
      return if event_loop.current?

      raise Phronomy::Error,
        "Workflow live-state progression must run on EventLoop"
    end

    def complete_task(task, value)
      task.complete(value)
    end

    def fail_task(task, error)
      task.fail(error)
    end

    def failed_task(name, error)
      task = Phronomy::Task.deferred(name: name)
      fail_task(task, error)
      task
    end
  end
end
