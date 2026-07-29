# frozen_string_literal: true

module Phronomy
  # Event-driven execution wrapper for a single FSM session.
  #
  # Used by WorkflowRunner and Agent/Tool Invocation builders. All public
  # methods are called from the EventLoop thread; FSMSession is not thread-safe.
  class FSMSession
    FINISH = WorkflowRunner::FINISH

    attr_reader :id

    def initialize(id:, context:, entry_point:, entry_actions:, auto_state_set:,
      declared_states:, wait_state_names:, external_events:, phase_machine_class:,
      recursion_limit:, event_loop:, timer_queue_provider:, action_timeouts: {},
      resume_event: nil, resume_phase: nil)
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
      @event_loop = event_loop
      @timer_queue_provider = timer_queue_provider
      @resume_event = resume_event
      @resume_phase = resume_phase
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
        @tracker.session_id = @id if @tracker.respond_to?(:session_id=)
        fire_and_advance!(@resume_event)
      else
        @current_state = @entry_point
        @tracker = build_tracker(@current_state)
        @tracker.context = @ctx
        @tracker.session_id = @id if @tracker.respond_to?(:session_id=)
        (@entry_actions[@current_state] || []).each do |callable|
          result = callable.call(@ctx)
          if result.is_a?(Phronomy::Task)
            @tracker.async_pending = true
            session_id = @id
            current_state_name = @current_state
            timeout_secs = @action_timeouts[current_state_name]
            if timeout_secs
              @timer_queue_provider.call.schedule(seconds: timeout_secs) do
                next if result.done?

                @event_loop.post(
                  Event.new(
                    type: :error,
                    target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
                    payload: {
                      session_id: session_id,
                      result: Phronomy::ActionTimeoutError.new(
                        "Action in state #{current_state_name.inspect} timed out after #{timeout_secs}s"
                      )
                    }
                  )
                )
              end
            end
            result.on_complete do |task_result, error|
              event = if error
                Event.new(
                  type: :error,
                  target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
                  payload: {session_id: session_id, result: error}
                )
              else
                Event.new(
                  type: :action_completed,
                  target_id: session_id,
                  payload: task_result
                )
              end
              @event_loop.post(event)
            end
            break
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

    def handle(event)
      return if @done

      if event.type == :action_completed
        apply_action_result(event.payload)
        @tracker.context = @ctx
        @tracker.async_pending = false
        advance_or_halt
        return
      end

      if event.type == :state_completed
        @tracker.async_pending = false if @tracker.async_pending
        fire_and_advance!(event.type)
        return
      end

      handled_by_context = @ctx.respond_to?(:handle_fsm_event) &&
        @ctx.handle_fsm_event(event)
      if handled_by_context && !has_external_event_from?(@current_state, event.type)
        return
      end

      fire_and_advance!(event.type)
    rescue => e
      finish_with_error(e)
    end

    private

    def apply_action_result(payload)
      if _fsm_context?(payload)
        @ctx = payload
      elsif @ctx.respond_to?(:apply_fsm_action_result)
        updated = @ctx.apply_fsm_action_result(payload)
        @ctx = updated if _fsm_context?(updated)
      end
    end

    def fire_and_advance!(event_name)
      if @step >= @recursion_limit
        raise Phronomy::RecursionLimitError,
          "Recursion limit (#{@recursion_limit}) exceeded"
      end

      fire_event!(@tracker, event_name, @current_state)
      @ctx = @tracker.context
      next_phase = @tracker.phase.to_sym
      @current_state = (next_phase == @current_state) ? FINISH : next_phase
      @step += 1

      if @tracker.async_pending
        @tracker.async_pending = false
        return
      end

      advance_or_halt
    end

    def advance_or_halt
      return finish! if @current_state == FINISH

      if @wait_state_names.include?(@current_state)
        return halt!
      end

      if @auto_state_set.key?(@current_state)
        @event_loop.post(Event.new(type: :state_completed, target_id: @id, payload: nil))
        return
      end

      if has_external_event_from?(@current_state)
        return
      end

      unless @declared_states.include?(@current_state)
        raise ArgumentError, "State #{@current_state.inspect} is not defined"
      end

      finish!
    end

    def finish!
      @done = true
      @ctx.set_graph_metadata(thread_id: @id, phase: :__end__)
      @event_loop.post(
        Event.new(
          type: :finished,
          target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
          payload: {session_id: @id, result: @ctx}
        )
      )
    end

    def halt!
      @done = true
      @ctx.set_graph_metadata(thread_id: @id, phase: @current_state)
      @event_loop.post(
        Event.new(
          type: :halted,
          target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
          payload: {session_id: @id, result: @ctx}
        )
      )
    end

    def finish_with_error(error)
      @done = true
      @event_loop.post(
        Event.new(
          type: :error,
          target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
          payload: {session_id: @id, result: error}
        )
      )
    end

    def fire_event!(tracker, event_name, from_state)
      return if tracker.send(event_name)

      raise ArgumentError,
        "Transition from #{from_state.inspect} via event #{event_name.inspect} failed. " \
        "Ensure at least one guard matches or add a fallback (no-guard) transition."
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
      machine.event_loop = @event_loop if machine.respond_to?(:event_loop=)
      if machine.respond_to?(:timer_queue_provider=)
        machine.timer_queue_provider = @timer_queue_provider
      end
      machine
    end

    def _fsm_context?(object)
      object.respond_to?(:set_graph_metadata)
    end
  end
end
