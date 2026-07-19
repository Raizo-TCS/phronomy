# frozen_string_literal: true

module Phronomy
  # Event-driven execution wrapper for a single FSM session.
  #
  # Used by both WorkflowRunner (for Workflow) and Agent::InvocationSession
  # (for Agent invoke). Not Workflow-specific.
  #
  # Created by a runner and registered with EventLoop. All public methods
  # are called from the EventLoop thread — FSMSession is NOT thread-safe and must
  # not be accessed concurrently from multiple threads.
  #
  class FSMSession
    FINISH = WorkflowRunner::FINISH

    # @return [String] workflow thread_id (matches WorkflowContext#thread_id)
    attr_reader :id

    # @param id                  [String]
    # @param context             [Object]        includes Phronomy::WorkflowContext
    # @param entry_point         [Symbol]        initial state name
    # @param entry_actions       [Hash]          { state_name => [callable, ...] }
    # @param auto_state_set      [Hash]          { state_name => true }
    # @param declared_states     [Array<Symbol>] all action state names
    # @param wait_state_names    [Array<Symbol>]
    # @param external_events     [Hash]          { event_name => [{from:, to:, guard:}] }
    # @param phase_machine_class [Class]         state_machines-backed phase tracker class
    # @param recursion_limit     [Integer]
    # @param action_timeouts     [Hash]          { state_name => seconds }
    # @param resume_event        [Symbol, nil]   external event to fire when resuming
    # @param resume_phase        [Symbol, nil]   wait state name to resume from
    # @api private
    def initialize(id:, context:, entry_point:, entry_actions:, auto_state_set:,
      declared_states:, wait_state_names:, external_events:, phase_machine_class:,
      recursion_limit:, action_timeouts: {}, resume_event: nil, resume_phase: nil)
      @id = id
      @ctx = context
      @entry_point = entry_point
      @entry_actions = entry_actions
      @auto_state_set = auto_state_set
      @declared_states = declared_states
      @wait_state_names = wait_state_names
      @external_events = external_events
      @phase_machine_class = phase_machine_class
      @recursion_limit = recursion_limit
      @action_timeouts = action_timeouts
      @resume_event = resume_event
      @resume_phase = resume_phase
      @step = 0
      @done = false
      @current_state = nil
      @tracker = nil
    end

    # Begins workflow execution. Called by EventLoop on :start event.
    def start
      if @resume_event
        # Resume from wait state: position tracker at the wait state, then fire the
        # external event. state_machines fires before_transition (exit) and
        # after_transition (entry) callbacks, so both actions execute here.
        @current_state = @resume_phase
        @tracker = build_tracker(@current_state)
        @tracker.context = @ctx
        @tracker.session_id = @id if @tracker.respond_to?(:session_id=)
        fire_and_advance!(@resume_event)
      else
        # Fresh start: state_machines does not fire callbacks on initialization,
        # so we invoke the entry action for the initial state manually.
        @current_state = @entry_point
        @tracker = build_tracker(@current_state)
        @tracker.context = @ctx
        @tracker.session_id = @id if @tracker.respond_to?(:session_id=)
        (@entry_actions[@current_state] || []).each do |c|
          result = c.call(@ctx)
          if result.is_a?(Phronomy::Task)
            # Awaitable action: resume via on_complete without blocking EventLoop.
            @tracker.async_pending = true
            session_id = @id
            current_state_name = @current_state
            timeout_secs = @action_timeouts[current_state_name]
            if timeout_secs
              Phronomy::Runtime.instance.timer_queue.schedule(seconds: timeout_secs) do
                next if result.done?

                event_loop.post(
                  Event.new(
                    type: :error,
                    target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
                    payload: {session_id: session_id, result: Phronomy::ActionTimeoutError.new(
                      "Action in state #{current_state_name.inspect} timed out after #{timeout_secs}s"
                    )}
                  )
                )
              end
            end
            result.on_complete do |task_result, error|
              if error
                event_loop.post(Event.new(type: :error, target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID, payload: {session_id: session_id, result: error}))
                next
              end
              if _fsm_context?(task_result)
                event_loop.post(Event.new(type: :action_completed, target_id: session_id, payload: task_result))
              else
                event_loop.post(Event.new(type: :state_completed, target_id: session_id, payload: nil))
              end
            end
            break # Only one async action at a time per state
          elsif _fsm_context?(result)
            @ctx = result
          end
        end
        @tracker.context = @ctx
        advance_or_halt unless @tracker.async_pending
      end
    rescue => e
      finish_with_error(e)
    end

    # Processes an event dispatched from EventLoop.
    # Called for :state_completed, :action_completed, and all user-defined external events.
    #
    # @param event [Phronomy::Event]
    # @api private
    def handle(event)
      return if @done

      if event.type == :action_completed
        # An awaitable entry action completed: update context and advance.
        @ctx = event.payload if _fsm_context?(event.payload)
        @tracker.context = @ctx
        @tracker.async_pending = false  # Reset flag set by start or fire_and_advance!
        advance_or_halt
        return
      end

      # When :state_completed arrives from an async Task (non-WorkflowContext result),
      # async_pending may still be true from the spawn. Clear it before advancing.
      @tracker.async_pending = false if event.type == :state_completed && @tracker.async_pending

      fire_and_advance!(event.type)
    rescue => e
      finish_with_error(e)
    end

    private

    # Fires event_name on the phase tracker, updates @current_state, then
    # calls advance_or_halt to decide what to do next.
    def fire_and_advance!(event_name)
      if @step >= @recursion_limit
        raise Phronomy::RecursionLimitError,
          "Recursion limit (#{@recursion_limit}) exceeded"
      end

      fire_event!(@tracker, event_name, @current_state)
      @ctx = @tracker.context
      next_phase = @tracker.phase.to_sym
      # When next_phase == @current_state, no transition matched → treat as terminal.
      @current_state = (next_phase == @current_state) ? FINISH : next_phase
      @step += 1

      # If an entry action returned a Task, the after_transition callback set
      # async_pending = true and spawned a thread. Skip advance_or_halt — the
      # background thread will post :action_completed or :state_completed.
      if @tracker.async_pending
        @tracker.async_pending = false
        return
      end

      advance_or_halt
    end

    # Determines the next action after the FSM has entered @current_state.
    def advance_or_halt
      return finish! if @current_state == FINISH

      if @wait_state_names.include?(@current_state)
        return halt!
      end

      if @auto_state_set.key?(@current_state)
        event_loop.post(Event.new(type: :state_completed, target_id: @id, payload: nil))
        return
      end

      if has_external_event_from?(@current_state)
        # Async IO pattern: the entry action spawned an IO thread that will post
        # an external event back. Stay registered; do nothing here.
        return
      end

      # No transition declared — validate the state is known, then treat as terminal.
      unless @declared_states.include?(@current_state)
        raise ArgumentError, "State #{@current_state.inspect} is not defined"
      end

      finish!
    end

    def finish!
      @done = true
      @ctx.set_graph_metadata(thread_id: @id, phase: :__end__)
      event_loop.post(Event.new(type: :finished, target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID, payload: {session_id: @id, result: @ctx}))
    end

    def halt!
      @done = true
      @ctx.set_graph_metadata(thread_id: @id, phase: @current_state)
      event_loop.post(Event.new(type: :halted, target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID, payload: {session_id: @id, result: @ctx}))
    end

    def finish_with_error(err)
      @done = true
      event_loop.post(Event.new(type: :error, target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID, payload: {session_id: @id, result: err}))
    end

    def fire_event!(tracker, event_name, from_state)
      return if tracker.send(event_name)

      raise ArgumentError,
        "Transition from #{from_state.inspect} via event #{event_name.inspect} failed. " \
        "Ensure at least one guard matches or add a fallback (no-guard) transition."
    end

    def has_external_event_from?(state)
      @external_events.any? { |_, transitions| transitions.any? { |t| t[:from] == state } }
    end

    def build_tracker(from_state)
      machine = @phase_machine_class.new
      machine.instance_variable_set(:@phase, from_state.to_s)
      machine
    end

    def event_loop
      Phronomy::EventLoop.instance
    end

    # Returns true when +obj+ is an FSM execution context (responds to
    # +set_graph_metadata+). Used to distinguish context objects from other
    # Task return values (strings, hashes, etc.) without hard-coding a specific
    # class. Both WorkflowContext and Agent::InvocationContext qualify.
    # @api private
    def _fsm_context?(obj)
      obj.respond_to?(:set_graph_metadata)
    end
  end
end
