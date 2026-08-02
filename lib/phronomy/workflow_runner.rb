# frozen_string_literal: true

require "securerandom"

module Phronomy
  # Execution boundary for compiled Workflows.
  #
  # WorkflowRunner prepares WorkflowContext instances, registers FSMSession
  # objects with the Runtime-owned EventLoop, observes completion, and persists
  # serializable Workflow snapshots. All Workflow execution APIs share this
  # path; their only differences are blocking and observation semantics.
  #
  # @api private
  class WorkflowRunner
    include Phronomy::Runnable

    FINISH = :__end__

    Execution = Data.define(
      :context,
      :thread_id,
      :recursion_limit,
      :store,
      :persist
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
      state_store: nil
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
      @state_store = state_store
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
        execution = prepare_new_execution(input, config)
        result = start_execution(execution).wait_result
        [result, nil]
      end
    end

    def invoke_deferred(input, config: {})
      execution = prepare_new_execution(input, config)
      start_execution(execution)
    rescue => error
      failed_task("workflow-async:preparation", error)
    end

    def stream(input, config: {}, &observer)
      ensure_blocking_call_allowed!(:stream, :invoke_async)
      raise ArgumentError, "stream requires a block" unless observer

      execution = prepare_new_execution(input, config)
      start_execution(
        execution,
        stable_observer: observer
      ).wait_result
    end

    def resume(state:, input: nil)
      send_event(state: state, event: :resume, input: input)
    end

    def send_event(state:, event:, input: nil)
      ensure_blocking_call_allowed!(:send_event, :signal)
      context = input ? state.merge(input) : state
      current_phase = context.phase.to_sym
      event_name = resolve_resume_event(current_phase, event)
      thread_id = context.thread_id
      unless thread_id
        raise ArgumentError, "Halted WorkflowContext has no thread_id"
      end

      execution = Execution.new(
        context: context,
        thread_id: thread_id.to_s,
        recursion_limit: Phronomy.configuration.recursion_limit,
        store: configured_store,
        persist: true
      )
      start_execution(
        execution,
        resume_event: event_name,
        resume_phase: current_phase
      ).wait_result
    end

    # Posts an application-defined event to a currently live Workflow session.
    #
    # Admission is asynchronous. A true result means the EventLoop accepted the
    # event for an admitted session; it does not mean that a transition matched.
    # A false result means that the Runtime is stopping or the session is no
    # longer admitted.
    def signal(thread_id:, event:, payload: nil)
      if thread_id.nil?
        raise ArgumentError, "thread_id is required"
      end

      event_name = event.to_sym
      unless @external_events.key?(event_name)
        raise ArgumentError,
          "Unknown event #{event_name.inspect}. " \
          "Valid events: #{@external_events.keys.inspect}"
      end

      Phronomy::Runtime.instance.event_loop.post_to_session(
        Phronomy::Event.new(
          type: event_name,
          target_id: thread_id.to_s,
          payload: payload
        )
      )
    end

    private

    def ensure_blocking_call_allowed!(method_name, async_alternative)
      return unless Phronomy::Runtime.instance.event_loop.current?

      raise Phronomy::Error,
        "Cannot call Workflow##{method_name} from the EventLoop thread. " \
        "Use #{async_alternative} instead."
    end

    def prepare_new_execution(input, config)
      thread_id = (config[:thread_id] || SecureRandom.uuid).to_s
      recursion_limit = config.fetch(
        :recursion_limit,
        Phronomy.configuration.recursion_limit
      )
      store = configured_store(config)
      snapshot = store&.load(thread_id) if config[:thread_id]

      stored_fields = snapshot && snapshot[:fields]
      initial_fields = if stored_fields
        stored_fields
          .transform_keys(&:to_sym)
          .merge(input.transform_keys(&:to_sym))
      else
        input
      end

      context = @state_class.new(**initial_fields)
      context.set_graph_metadata(thread_id: thread_id)

      Execution.new(
        context: context,
        thread_id: thread_id,
        recursion_limit: recursion_limit,
        store: store,
        persist: !config[:thread_id].nil?
      )
    end

    def configured_store(config = {})
      config.fetch(:state_store, @state_store) ||
        Phronomy.configuration.state_store
    end

    def start_execution(
      execution,
      resume_event: nil,
      resume_phase: nil,
      stable_observer: nil
    )
      runtime = Phronomy::Runtime.instance
      result_task = Phronomy::Task.deferred(
        name: "workflow:#{execution.thread_id}"
      )
      source_task = Phronomy::Task.deferred(
        name: "workflow-source:#{execution.thread_id}"
      )

      source_task.on_complete do |result, error|
        finalize_execution(
          result_task: result_task,
          result: result,
          error: error,
          store: execution.store,
          thread_id: execution.thread_id,
          persist: execution.persist
        )
      end

      session = build_session_for(
        context: execution.context,
        recursion_limit: execution.recursion_limit,
        runtime: runtime,
        resume_event: resume_event,
        resume_phase: resume_phase,
        stable_observer: stable_observer
      )
      runtime.event_loop.register(session, completion: source_task)
      result_task
    rescue => error
      fail_task(result_task, error) if result_task
      result_task || failed_task("workflow:registration", error)
    end

    def finalize_execution(
      result_task:,
      result:,
      error:,
      store:,
      thread_id:,
      persist:
    )
      if error
        fail_task(result_task, error)
        return
      end

      begin
        persist_snapshot(store, thread_id, result, persist: persist)
      rescue => persistence_error
        fail_task(result_task, persistence_error)
        return
      end

      complete_task(result_task, result)
    end

    def persist_snapshot(store, thread_id, context, persist:)
      return unless store && persist

      store.save(
        thread_id,
        {
          fields: context.to_h,
          phase: context.phase.to_s
        }
      )
    end

    def build_session_for(
      context:,
      recursion_limit:,
      runtime:,
      resume_event: nil,
      resume_phase: nil,
      stable_observer: nil
    )
      Phronomy::FSMSession.new(
        id: context.thread_id,
        context: context,
        entry_point: @entry_point,
        entry_actions: @entry_actions,
        auto_state_set: @auto_state_set,
        declared_states: @declared_states,
        wait_state_names: @wait_state_names,
        external_events: @external_events,
        phase_machine_class: @phase_machine_class,
        recursion_limit: recursion_limit,
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
      task.backend.unblock(value, nil)
      task.transition!(:completed, value: value)
    end

    def fail_task(task, error)
      task.backend.unblock(nil, error)
      task.transition!(:failed, error: error)
    end

    def failed_task(name, error)
      task = Phronomy::Task.deferred(name: name)
      fail_task(task, error)
      task
    end
  end
end
