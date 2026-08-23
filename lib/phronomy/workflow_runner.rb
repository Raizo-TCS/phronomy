# frozen_string_literal: true

require "securerandom"

module Phronomy
  # Execution boundary for compiled Workflows.
  #
  # WorkflowRunner separates three identities:
  # - application session_id remains caller/tracing metadata;
  # - workflow_instance_id identifies durable Workflow state;
  # - fsm_session_id identifies one concrete Runtime FSMSession incarnation.
  #
  # Workflow persistence is synchronous at the repository contract but is always
  # invoked through Runtime's OffloadPool from EventLoop-driven lifecycle paths.
  # @api private
  class WorkflowRunner
    include Phronomy::Runnable

    FINISH = :__end__

    Execution = Data.define(
      :context,
      :workflow_instance_id,
      :fsm_session_id,
      :fsm_identity_reservation,
      :recursion_limit,
      :repository,
      :persist,
      :expected_revision
    )

    WorkflowPersistenceCommand = Struct.new(
      :runner,
      :result_task,
      :result,
      :error,
      :workflow_instance_id,
      :fsm_session_id
    )

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
      caller_meta = {}
      caller_meta[:user_id] = config[:user_id] if config[:user_id]
      caller_meta[:session_id] = config[:session_id] if config[:session_id]

      trace("workflow.invoke", input: input.inspect, **caller_meta) do |_span|
        result = start_new_execution(input, config).wait_result
        [result, nil]
      end
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
    # workflow_instance_id is resolved to its Runtime-only fsm_session_id by EventLoop; the
    # application session_id is deliberately unrelated to this routing.
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

    # Called only by EventLoop for terminal Workflow persistence completion.
    def deliver_persistence_on_event_loop(command)
      event_loop = Phronomy::Runtime.instance.event_loop
      event_loop.release_workflow(
        command.workflow_instance_id,
        owner_fsm_session_id: command.fsm_session_id
      )
      if command.error
        fail_task(command.result_task, command.error)
      else
        complete_task(command.result_task, command.result)
      end
    end

    private

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
      event_loop = runtime.event_loop
      result_task = Phronomy::Task.deferred(name: "workflow:preparing")
      explicit_workflow_instance_id = !config[:workflow_instance_id].nil?
      workflow_instance_id = (config[:workflow_instance_id] || SecureRandom.uuid).to_s
      fsm_identity_reservation = Phronomy::FSMSession.reserve_identity
      fsm_session_id = fsm_identity_reservation.fsm_session_id
      recursion_limit = config.fetch(
        :recursion_limit,
        Phronomy.configuration.recursion_limit
      )
      repository = configured_repository
      persist = explicit_workflow_instance_id && !repository.nil?

      event_loop.admit_workflow(
        workflow_instance_id,
        owner_fsm_session_id: fsm_session_id
      )

      if persist
        load_operation = runtime.offload.submit(on_full: :raise) do
          repository.load(workflow_instance_id)
        end
        load_operation.on_complete do |record, error|
          if error
            release_and_fail(
              event_loop, result_task, workflow_instance_id, fsm_session_id, error
            )
            next
          end

          begin
            execution = build_new_execution(
              input,
              workflow_instance_id: workflow_instance_id,
              fsm_session_id: fsm_session_id,
              fsm_identity_reservation: fsm_identity_reservation,
              recursion_limit: recursion_limit,
              repository: repository,
              persist: true,
              record: record
            )
            register_execution(
              execution,
              result_task,
              stable_observer: stable_observer
            )
          rescue => preparation_error
            release_and_fail(
              event_loop,
              result_task,
              workflow_instance_id,
              fsm_session_id,
              preparation_error
            )
          end
        end
      else
        execution = build_new_execution(
          input,
          workflow_instance_id: workflow_instance_id,
          fsm_session_id: fsm_session_id,
          fsm_identity_reservation: fsm_identity_reservation,
          recursion_limit: recursion_limit,
          repository: repository,
          persist: false,
          record: nil
        )
        register_execution(
          execution,
          result_task,
          stable_observer: stable_observer
        )
      end
      result_task
    rescue => error
      if defined?(event_loop) && event_loop &&
          defined?(workflow_instance_id) && defined?(fsm_session_id)
        event_loop.release_workflow(
          workflow_instance_id,
          owner_fsm_session_id: fsm_session_id
        )
      end
      fail_task(result_task, error) if defined?(result_task) && result_task
      result_task || failed_task("workflow:preparation", error)
    end

    def start_resume_execution(state, input:, event_name:, current_phase:)
      runtime = Phronomy::Runtime.instance
      event_loop = runtime.event_loop
      workflow_instance_id = state.workflow_instance_id.to_s
      fsm_identity_reservation = Phronomy::FSMSession.reserve_identity
      fsm_session_id = fsm_identity_reservation.fsm_session_id
      repository = configured_repository
      result_task = Phronomy::Task.deferred(name: "workflow-resume:#{workflow_instance_id}")

      event_loop.admit_workflow(
        workflow_instance_id,
        owner_fsm_session_id: fsm_session_id
      )

      if repository
        load_operation = runtime.offload.submit(on_full: :raise) do
          repository.load(workflow_instance_id)
        end
        load_operation.on_complete do |record, error|
          if error
            release_and_fail(
              event_loop, result_task, workflow_instance_id, fsm_session_id, error
            )
            next
          end

          begin
            expected_revision = validate_resume_snapshot!(state, record)
            context = input ? state.merge(input) : state
            execution = Execution.new(
              context: context,
              workflow_instance_id: workflow_instance_id,
              fsm_session_id: fsm_session_id,
              fsm_identity_reservation: fsm_identity_reservation,
              recursion_limit: Phronomy.configuration.recursion_limit,
              repository: repository,
              persist: true,
              expected_revision: expected_revision
            )
            register_execution(
              execution,
              result_task,
              resume_event: event_name,
              resume_phase: current_phase
            )
          rescue => preparation_error
            release_and_fail(
              event_loop,
              result_task,
              workflow_instance_id,
              fsm_session_id,
              preparation_error
            )
          end
        end
      else
        context = input ? state.merge(input) : state
        execution = Execution.new(
          context: context,
          workflow_instance_id: workflow_instance_id,
          fsm_session_id: fsm_session_id,
          fsm_identity_reservation: fsm_identity_reservation,
          recursion_limit: Phronomy.configuration.recursion_limit,
          repository: nil,
          persist: false,
          expected_revision: nil
        )
        register_execution(
          execution,
          result_task,
          resume_event: event_name,
          resume_phase: current_phase
        )
      end
      result_task
    rescue => error
      if defined?(event_loop) && event_loop &&
          defined?(workflow_instance_id) && defined?(fsm_session_id)
        event_loop.release_workflow(
          workflow_instance_id,
          owner_fsm_session_id: fsm_session_id
        )
      end
      fail_task(result_task, error) if defined?(result_task) && result_task
      result_task || failed_task("workflow:resume-preparation", error)
    end

    def build_new_execution(
      input,
      workflow_instance_id:,
      fsm_session_id:,
      fsm_identity_reservation:,
      recursion_limit:,
      repository:,
      persist:,
      record:
    )
      snapshot = record_value(record, :snapshot)
      stored_fields = snapshot && (snapshot[:fields] || snapshot["fields"])
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
        fsm_session_id: fsm_session_id,
        fsm_identity_reservation: fsm_identity_reservation,
        recursion_limit: recursion_limit,
        repository: repository,
        persist: persist,
        expected_revision: record_value(record, :revision)
      )
    end

    def validate_resume_snapshot!(state, record)
      return nil unless record

      durable_snapshot = normalize_snapshot(record_value(record, :snapshot))
      local_snapshot = normalize_snapshot(snapshot_for(state))
      return record_value(record, :revision) if durable_snapshot == local_snapshot

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
      source_task = Phronomy::Task.deferred(
        name: "workflow-source:#{execution.fsm_session_id}"
      )

      source_task.on_complete do |result, error|
        finalize_execution(
          execution: execution,
          result_task: result_task,
          result: result,
          error: error
        )
      end

      session = build_session_for(
        execution: execution,
        runtime: runtime,
        resume_event: resume_event,
        resume_phase: resume_phase,
        stable_observer: stable_observer
      )
      runtime.event_loop.register(session, completion: source_task)
      result_task
    rescue => error
      Phronomy::Runtime.instance.event_loop.release_workflow(
        execution.workflow_instance_id,
        owner_fsm_session_id: execution.fsm_session_id
      )
      fail_task(result_task, error)
      result_task
    end

    # Called from source_task completion on EventLoop.
    def finalize_execution(execution:, result_task:, result:, error:)
      event_loop = Phronomy::Runtime.instance.event_loop
      if error
        event_loop.release_workflow(
          execution.workflow_instance_id,
          owner_fsm_session_id: execution.fsm_session_id
        )
        fail_task(result_task, error)
        return
      end

      unless execution.repository && execution.persist
        event_loop.release_workflow(
          execution.workflow_instance_id,
          owner_fsm_session_id: execution.fsm_session_id
        )
        complete_task(result_task, result)
        return
      end

      snapshot = snapshot_for(result)
      runtime = Phronomy::Runtime.instance
      operation = runtime.offload.submit(on_full: :raise) do
        execution.repository.save(
          execution.workflow_instance_id,
          expected_revision: execution.expected_revision,
          snapshot: snapshot
        )
      end
      operation.on_complete do |_revision, persistence_error|
        command = WorkflowPersistenceCommand.new(
          self,
          result_task,
          result,
          persistence_error,
          execution.workflow_instance_id,
          execution.fsm_session_id
        )
        posted = event_loop.post(
          Phronomy::Event.new(
            type: :workflow_persistence_ready,
            target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
            payload: {command: command}
          )
        )
        settle_persistence_without_event_loop(command, event_loop) unless posted
      end
    rescue => persistence_start_error
      event_loop.release_workflow(
        execution.workflow_instance_id,
        owner_fsm_session_id: execution.fsm_session_id
      )
      fail_task(result_task, persistence_start_error)
    end

    def settle_persistence_without_event_loop(command, event_loop)
      event_loop.release_workflow(
        command.workflow_instance_id,
        owner_fsm_session_id: command.fsm_session_id
      )
      command.error ?
        fail_task(command.result_task, command.error) :
        complete_task(command.result_task, command.result)
    rescue => error
      fail_task(command.result_task, error)
    end

    def release_and_fail(event_loop, result_task, workflow_instance_id, fsm_session_id, error)
      event_loop.release_workflow(
        workflow_instance_id,
        owner_fsm_session_id: fsm_session_id
      )
      fail_task(result_task, error)
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
      Phronomy::FSMSession.new(
        identity_reservation: execution.fsm_identity_reservation,
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
        stable_observer: stable_observer
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
