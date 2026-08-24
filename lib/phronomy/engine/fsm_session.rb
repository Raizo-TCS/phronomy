# frozen_string_literal: true

require "securerandom"

module Phronomy
  # Event-driven execution wrapper for a single FSM session.
  #
  # All public methods are called from the Runtime-owned EventLoop thread.
  # FSMSession owns FSM execution only; it does not own external Task handles,
  # activity tokens, callback correlation, or domain-specific stale-event policy.
  class FSMSession
    class IdentityReservation
      attr_reader :fsm_session_id

      def initialize
        @fsm_session_id = SecureRandom.uuid.to_s.freeze
        @claimed = false
        @mutex = Mutex.new
      end

      def claim!
        @mutex.synchronize do
          raise Phronomy::Error, "FSMSession identity reservation already claimed" if @claimed

          @claimed = true
          @fsm_session_id
        end
      end
    end
    private_constant :IdentityReservation

    class EventSink
      attr_reader :fsm_session_id

      def initialize(event_loop:)
        @event_loop = event_loop
        @fsm_session_id = nil
      end

      def bind!(fsm_session_id)
        raise Phronomy::Error, "FSMSession EventSink is already bound" if @fsm_session_id

        @fsm_session_id = fsm_session_id.to_s.freeze
        self
      end

      def post(type, payload = nil)
        raise Phronomy::Error, "FSMSession EventSink is not bound" unless @fsm_session_id

        event = Phronomy::Event.new(
          type: type,
          target_id: @fsm_session_id,
          payload: payload
        )
        if @event_loop.respond_to?(:post_to_session)
          @event_loop.post_to_session(event)
        else
          @event_loop.post(event)
        end
      end
    end

    FINISH = WorkflowRunner::FINISH

    attr_reader :id, :context, :event_sink

    # Returns the live current Workflow phase. During an active FSM transition
    # the tracker phase is authoritative; @current_state lags until
    # fire_and_advance! returns. Terminal persistence lifecycle is deliberately
    # separate from this logical Workflow phase.
    def current_state
      return @tracker.phase.to_sym if @tracker
      @current_state
    end

    # @api private
    def self.reserve_identity
      IdentityReservation.new
    end

    def initialize(
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
      stable_observer: nil,
      context_metadata: {},
      event_sink: nil,
      identity_reservation: nil,
      terminal_barrier: nil
    )
      @id = if identity_reservation
        unless identity_reservation.is_a?(IdentityReservation)
          raise ArgumentError,
            "identity_reservation must come from FSMSession.reserve_identity"
        end
        identity_reservation.send(:claim!).to_s.freeze
      else
        SecureRandom.uuid.to_s.freeze
      end
      @event_sink = event_sink || EventSink.new(event_loop: event_loop)
      @event_sink.bind!(@id)
      @context_metadata = context_metadata.dup.freeze
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
      @terminal_barrier = terminal_barrier
      @terminal_lifecycle_state = :running
      @pending_terminal_type = nil
      @pending_terminal_notify_stable = false
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

      if event.type == :workflow_terminal_persistence_result
        handle_terminal_persistence_result(event.payload)
        return
      end

      # Once terminal persistence begins, ordinary Workflow events no longer
      # have result authority. Only the persistence completion for this concrete
      # FSMSession can advance its terminal lifecycle.
      return unless @terminal_lifecycle_state == :running

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

    attr_reader :terminal_lifecycle_state

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
        apply_context_metadata!
      end
    end

    def apply_context_event(event)
      return false unless @ctx.respond_to?(:handle_fsm_event)

      result = @ctx.handle_fsm_event(event)
      return :consume if result == :consume

      if _fsm_context?(result)
        @ctx = result
        @context = result
        apply_context_metadata!
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
      apply_context_metadata!
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

      # A wait state is the logical end of this Workflow execution segment. Its
      # public stable-state notification is therefore part of terminalization
      # and, for durable Workflows, must not escape before the durable barrier.
      if @wait_state_names.include?(@current_state)
        halt!
        return
      end

      if @auto_state_set.key?(@current_state)
        notify_stable_state!
        post_session_event(:state_completed)
        return
      end

      if has_external_event_from?(@current_state)
        notify_stable_state!
        return
      end

      unless @declared_states.include?(@current_state)
        raise ArgumentError, "State #{@current_state.inspect} is not defined"
      end

      # A declared state with no outgoing transition is also a logical terminal
      # boundary. Preserve its stable-state notification, but for durable
      # Workflows publish it only after the terminal save succeeds.
      finish!(notify_stable: true)
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

    def finish!(notify_stable: false)
      request_terminal!(
        :finished,
        phase: :__end__,
        notify_stable: notify_stable
      )
    end

    def halt!
      request_terminal!(:halted, phase: @current_state, notify_stable: true)
    end

    def request_terminal!(terminal_type, phase:, notify_stable:)
      return if @done || @terminal_lifecycle_state != :running

      apply_context_metadata!(phase: phase)
      @pending_terminal_type = terminal_type
      @pending_terminal_notify_stable = notify_stable
      unless @terminal_barrier
        complete_terminal!(terminal_type)
        return
      end

      @terminal_lifecycle_state = :persisting_terminal
      @terminal_barrier.call(
        terminal_type: terminal_type,
        context: @ctx,
        event_sink: @event_sink
      )
    rescue => error
      finish_with_error(error)
    end

    def handle_terminal_persistence_result(result)
      return unless @terminal_lifecycle_state == :persisting_terminal

      case result.outcome
      when :success
        complete_terminal!(@pending_terminal_type)
      when :known_failure
        finish_with_error(
          result.error || Phronomy::Error.new("Workflow terminal persistence failed")
        )
      when :outcome_unknown
        @done = true
        @terminal_lifecycle_state = :recovery_required
        post_recovery_required_event(result.error)
      else
        raise Phronomy::Error,
          "unknown Workflow terminal persistence outcome: #{result.outcome.inspect}"
      end
    end

    def complete_terminal!(terminal_type)
      @done = true
      @terminal_lifecycle_state =
        (terminal_type == :halted) ? :halted : :completed
      notify_stable_state! if @pending_terminal_notify_stable
      post_terminal_event(terminal_type, @ctx)
    end

    def finish_with_error(error)
      return if @done

      @done = true
      @terminal_lifecycle_state = :error
      post_terminal_event(:error, error)
    end

    def post_recovery_required_event(error)
      accepted = @event_loop.post(
        Phronomy::Event.new(
          type: :recovery_required,
          target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
          payload: {fsm_session_id: @id, error: error}
        )
      )
      return if accepted

      Phronomy.configuration.logger&.warn(
        "[Phronomy::FSMSession] EventLoop rejected recovery-required event for #{@id}"
      )
    end

    def post_terminal_event(type, result)
      accepted = @event_loop.post(
        Phronomy::Event.new(
          type: type,
          target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
          payload: {fsm_session_id: @id, result: result}
        )
      )
      return if accepted

      Phronomy.configuration.logger&.warn(
        "[Phronomy::FSMSession] EventLoop rejected terminal event " \
          "#{type.inspect} for #{@id}"
      )
    end

    def apply_context_metadata!(phase: nil)
      return unless @ctx.respond_to?(:set_graph_metadata)

      metadata = @context_metadata
      metadata = metadata.merge(phase: phase) unless phase.nil?
      @ctx.set_graph_metadata(**metadata)
    end

    def fire_event!(tracker, event_name, from_state)
      unless tracker.respond_to?(event_name)
        raise ArgumentError,
          "Unknown FSM event #{event_name.inspect} for state #{from_state.inspect}"
      end

      return true if tracker.public_send(event_name)

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
