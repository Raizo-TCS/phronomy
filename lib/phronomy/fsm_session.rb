# frozen_string_literal: true

module Phronomy
  # Event-driven execution wrapper for a single workflow run.
  #
  # Created by WorkflowRunner and registered with EventLoop. All public methods
  # are called from the EventLoop thread — FSMSession is NOT thread-safe and must
  # not be accessed concurrently from multiple threads.
  #
  # == Lifecycle
  #
  #   register(session) → EventLoop posts :start → session.start
  #                                 ↓ (auto-transition present)
  #                        EventLoop posts :state_completed → session.handle
  #                                 ↓ (repeat)
  #                        session posts :finished or :halted
  #                                 ↓
  #                        EventLoop pushes ctx to completion_queue → caller unblocks
  #
  # == Async IO pattern (EventLoop mode only)
  #
  # When a state has no auto-transition and is not a wait_state, but has an
  # external event registered (e.g. +transition from: :fetching, on: :fetch_done+),
  # the FSMSession stays registered in the EventLoop and waits for that event.
  # The entry action is expected to spawn an IO thread that posts the event back:
  #
  #   entry :fetching, ->(ctx) {
  #     Thread.new {
  #       ctx.result = http.get(ctx.url)
  #       Phronomy::EventLoop.instance.post(
  #         Phronomy::Event.new(type: :fetch_done, target_id: ctx.thread_id, payload: nil)
  #       )
  #     }
  #   }
  #   transition from: :fetching, on: :fetch_done, to: :process
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
        fire_and_advance!(@resume_event)
      else
        # Fresh start: state_machines does not fire callbacks on initialization,
        # so we invoke the entry action for the initial state manually.
        @current_state = @entry_point
        @tracker = build_tracker(@current_state)
        @tracker.context = @ctx
        (@entry_actions[@current_state] || []).each do |c|
          result = c.call(@ctx)
          if result.is_a?(Phronomy::Task)
            # Awaitable action: spawn a task to await without blocking EventLoop.
            @tracker.async_pending = true
            session_id = @id
            current_state_name = @current_state
            timeout_secs = @action_timeouts[current_state_name]
            Phronomy::Runtime.instance.spawn(name: "fsm-await-#{session_id}") do
              if timeout_secs
                if result.join(timeout_secs).nil?
                  result.cancel!
                  raise Phronomy::ActionTimeoutError,
                    "Action in state #{current_state_name.inspect} timed out after #{timeout_secs}s"
                end
              end
              task_result = result.await
              if task_result.is_a?(Phronomy::WorkflowContext)
                event_loop.post(Event.new(type: :action_completed, target_id: session_id, payload: task_result))
              else
                event_loop.post(Event.new(type: :state_completed, target_id: session_id, payload: nil))
              end
            rescue => e
              event_loop.post(Event.new(type: :error, target_id: session_id, payload: e))
            end
            break # Only one async action at a time per state
          elsif result.is_a?(Phronomy::WorkflowContext)
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
        @ctx = event.payload if event.payload.is_a?(Phronomy::WorkflowContext)
        @tracker.context = @ctx
        @tracker.async_pending = false  # Reset flag set by start or fire_and_advance!
        advance_or_halt
        return
      end

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
      event_loop.post(Event.new(type: :finished, target_id: @id, payload: @ctx))
    end

    def halt!
      @done = true
      @ctx.set_graph_metadata(thread_id: @id, phase: @current_state)
      event_loop.post(Event.new(type: :halted, target_id: @id, payload: @ctx))
    end

    def finish_with_error(err)
      @done = true
      event_loop.post(Event.new(type: :error, target_id: @id, payload: err))
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
  end
end
