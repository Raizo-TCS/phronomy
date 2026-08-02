# frozen_string_literal: true

module Phronomy
  # Event-driven execution wrapper for a single FSM session.
  #
  # All public methods are called from the Runtime-owned EventLoop thread.
  # FSMSession owns FSM execution only; it does not own external Task handles,
  # activity tokens, callback correlation, or domain-specific stale-event policy.
  class FSMSession
    FINISH = WorkflowRunner::FINISH

    attr_reader :id, :context

    def initialize(
      id:,
      context:,
      entry_point:,
      entry_actions:,
      auto_state_set:,
      declared_states:,
      wait_state_names:,
      external_events:,
      phase_machine_class:,
      recursion_limit:,
      event_loop:,
      resume_event: nil,
      resume_phase: nil,
      stable_observer: nil
    )
      @id = id
      @ctx = context
      @context = context
      @entry_point = entry_point
      @entry_actions = entry_actions
      @auto_state_set = auto_state_set
      @declared_states = declared_states
      @wait_state_names = wait_state_names
      @external_events = external_events
      @phase_machine_class = phase_machine_class
      @recursion_limit = recursion_limit
      @event_loop = event_loop
      @resume_event = resume_event
      @resume_phase = resume_phase
      @stable_observer = stable_observer
      @step = 0
      @done = false
      @current_state = nil
      @tracker = nil
    end

    def start
      if @resume_event
        @current_state = @resume_phase
        @tracker = build_tracker(@current_state)
        @tracker.context = @ctx
        fire_and_advance!(
          Phronomy::Event.new(
            type: @resume_event,
            target_id: @id,
            payload: nil
          )
        )
      else
        @current_state = @entry_point
        @tracker = build_tracker(@current_state)
        @tracker.context = @ctx
        run_initial_entry_actions!
        @tracker.context = @ctx
        advance_or_halt
      end
    rescue => error
      finish_with_error(error)
    end

    def handle(event)
      return if @done

      context_disposition = apply_context_event(event)
      return if context_disposition == :consume

      if context_disposition &&
          !has_external_event_from?(@current_state, event.type)
        return
      end

      fire_and_advance!(event)
    rescue => error
      finish_with_error(error)
    end

    private

    def run_initial_entry_actions!
      Array(@entry_actions[@current_state]).each do |callable|
        result = callable.call(@ctx)
        apply_synchronous_action_result!(result, @current_state)
      end
    end

    def apply_synchronous_action_result!(result, state_name)
      if result.is_a?(Phronomy::Task)
        raise Phronomy::InvalidAsyncEntryActionError,
          "Entry action for state #{state_name.inspect} returned Phronomy::Task. " \
          "Start the asynchronous operation, register its callback/listener, " \
          "and return the WorkflowContext or nil."
      end

      if _fsm_context?(result)
        @ctx = result
        @context = result
      end
    end

    def apply_context_event(event)
      return false unless @ctx.respond_to?(:handle_fsm_event)

      result = @ctx.handle_fsm_event(event)
      return :consume if result == :consume

      if _fsm_context?(result)
        @ctx = result
        @context = result
        @tracker.context = @ctx
        true
      else
        !!result
      end
    end

    def fire_and_advance!(event)
      if @step >= @recursion_limit
        raise Phronomy::RecursionLimitError,
          "Recursion limit (#{@recursion_limit}) exceeded"
      end

      @tracker.context = @ctx
      clear_selected_transition!
      @tracker.current_event = event if @tracker.respond_to?(:current_event=)
      transitioned = fire_event!(@tracker, event.type, @current_state)
      return unless transitioned

      @ctx = @tracker.context
      @context = @ctx
      @current_state = @tracker.phase.to_sym
      @step += 1
      advance_or_halt
    ensure
      @tracker.current_event = nil if @tracker&.respond_to?(:current_event=)
      clear_selected_transition!
    end

    def clear_selected_transition!
      return unless @tracker

      if @tracker.respond_to?(:selected_transition_action=)
        @tracker.selected_transition_action = nil
      end
      if @tracker.respond_to?(:selected_transition_metadata=)
        @tracker.selected_transition_metadata = nil
      end
    end

    def advance_or_halt
      return finish! if @current_state == FINISH

      notify_stable_state!

      if @wait_state_names.include?(@current_state)
        halt!
        return
      end

      if @auto_state_set.key?(@current_state)
        post_session_event(:state_completed)
        return
      end

      return if has_external_event_from?(@current_state)

      unless @declared_states.include?(@current_state)
        raise ArgumentError, "State #{@current_state.inspect} is not defined"
      end

      finish!
    end

    def notify_stable_state!
      return unless @stable_observer

      @stable_observer.call(
        {
          state: @current_state,
          context: @ctx
        }
      )
    end

    def post_session_event(type, payload = nil)
      event = Phronomy::Event.new(
        type: type,
        target_id: @id,
        payload: payload
      )
      accepted =
        if @event_loop.respond_to?(:post_to_session)
          @event_loop.post_to_session(event)
        else
          @event_loop.post(event)
        end
      return if accepted

      raise Phronomy::RuntimeShutdownError,
        "EventLoop rejected #{type.inspect} for FSMSession #{@id}"
    end

    def finish!
      return if @done

      @done = true
      @ctx.set_graph_metadata(thread_id: @id, phase: :__end__)
      post_terminal_event(:finished, @ctx)
    end

    def halt!
      return if @done

      @done = true
      @ctx.set_graph_metadata(thread_id: @id, phase: @current_state)
      post_terminal_event(:halted, @ctx)
    end

    def finish_with_error(error)
      return if @done

      @done = true
      post_terminal_event(:error, error)
    end

    def post_terminal_event(type, result)
      accepted = @event_loop.post(
        Phronomy::Event.new(
          type: type,
          target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
          payload: {session_id: @id, result: result}
        )
      )
      return if accepted

      Phronomy.configuration.logger&.warn(
        "[Phronomy::FSMSession] EventLoop rejected terminal event " \
        "#{type.inspect} for #{@id}"
      )
    end

    def fire_event!(tracker, event_name, from_state)
      unless tracker.respond_to?(event_name)
        raise ArgumentError,
          "Unknown FSM event #{event_name.inspect} for state #{from_state.inspect}"
      end

      return true if tracker.public_send(event_name)

      # A declared external event whose guards all reject is a valid no-op.
      # Applications use this to reject stale or unrelated correlated events.
      return false if has_external_event_from?(from_state, event_name)

      raise ArgumentError,
        "Transition from #{from_state.inspect} via event #{event_name.inspect} failed. " \
        "The event is not declared for the current state."
    end

    def has_external_event_from?(state, event_name = nil)
      events = event_name ? {event_name => @external_events[event_name]} : @external_events
      events.any? do |_name, transitions|
        Array(transitions).any? { |transition| transition[:from] == state }
      end
    end

    def build_tracker(from_state)
      machine = @phase_machine_class.new
      machine.instance_variable_set(:@phase, from_state.to_s)
      machine
    end

    def _fsm_context?(object)
      object.respond_to?(:set_graph_metadata)
    end
  end
end
