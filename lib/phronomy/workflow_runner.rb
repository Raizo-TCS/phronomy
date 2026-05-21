# frozen_string_literal: true

require "securerandom"
require "state_machines"

module Phronomy
  # Execution engine for compiled workflows.
  # Manages state entry/exit action execution, phase transitions, halt/resume, and wait states.
  # Instantiated by Phronomy::Workflow and used internally.
  #
  # == Design principle
  #
  # State transitions are driven entirely by state_machines. The PhaseTracker
  # holds a reference to the current WorkflowContext via +attr_accessor :context+,
  # and guard lambdas evaluate +m.context+ (the WorkflowContext) rather than
  # the PhaseTracker itself. This ensures that "what happens next" is always
  # determined by the declared state machine topology, never by Phronomy internals.
  #
  # Entry and exit actions are registered as state_machines +after_transition to:+
  # and +before_transition from:+ callbacks respectively. The WorkflowContext is
  # mutable; actions receive it and modify fields in place.
  #
  # The sole exception is the initial state: state_machines does not fire transition
  # callbacks on initialization, so the entry action for the entry point is invoked
  # directly by WorkflowRunner before the main execution loop begins.
  #
  # == Two transition categories registered in PhaseTracker
  #
  #   1. state_completed  — all auto-fire transitions (with or without guards).
  #                        Fired when an action state's action completes.
  #                        Guards are evaluated in declaration order; first match wins.
  #                        (declared with +transition from: :foo, to: :bar+ or
  #                         +transition from: :foo, guard: ..., to: :bar+)
  #
  #   2. <event_name>    — external events triggered by human input, originating
  #                        from wait states
  #                        (declared with +transition from: :awaiting, on: :approve, to: :run+)
  class WorkflowRunner
    include Phronomy::Runnable

    # Sentinel value for the terminal state of a workflow.
    FINISH = :__end__

    def initialize(state_class:, entry_actions:, declared_states:, auto_transitions:, external_events:, entry_point:, exit_actions: {}, wait_state_names: [])
      @state_class = state_class
      @entry_actions = entry_actions   # { state_name => [callable, ...] }
      @declared_states = declared_states
      # Lookup set: states with at least one auto-fire transition declared.
      @auto_state_set = auto_transitions.each_with_object({}) { |t, h| h[t[:from]] = true }
      @external_events = external_events    # { name => [{from:, to:, guard:}, ...] }
      @entry_point = entry_point
      @wait_state_names = wait_state_names
      @phase_machine_class = build_phase_machine_class(auto_transitions, exit_actions)
    end

    # Executes the workflow from the initial state.
    # @param input [Hash] initial context field values
    # @param config [Hash] { thread_id:, recursion_limit:, user_id:, session_id: }
    # @return [Object] final context (includes Phronomy::WorkflowContext)
    def invoke(input, config: {})
      caller_meta = {}
      caller_meta[:user_id] = config[:user_id] if config[:user_id]
      caller_meta[:session_id] = config[:session_id] if config[:session_id]

      trace("workflow.invoke", input: input.inspect, **caller_meta) do |_span|
        thread_id = config[:thread_id] || SecureRandom.uuid
        recursion_limit = config.fetch(:recursion_limit, Phronomy.configuration.recursion_limit)
        state = @state_class.new(**input)
        state.set_graph_metadata(thread_id: thread_id)
        result = if Phronomy.configuration.event_loop
          run_via_event_loop(state, recursion_limit: recursion_limit)
        else
          run_workflow(state, recursion_limit: recursion_limit)
        end
        [result, nil]
      end
    end

    # Generic resume. Equivalent to +send_event(state:, event: :resume, input:)+.
    # @param state [Object] halted context
    # @param input [Hash, nil] optional field updates to merge before resuming
    # @return [Object] final context
    def resume(state:, input: nil)
      send_event(state: state, event: :resume, input: input)
    end

    # Fires a named event to advance a halted workflow.
    #
    # The special event +:resume+ selects the first external event registered
    # for the current wait state and fires it.
    #
    # @param state [Object] halted context
    # @param event [Symbol] named event or +:resume+ for generic resumption
    # @param input [Hash, nil] optional field updates to merge before resuming
    # @return [Object] final context
    def send_event(state:, event:, input: nil)
      state = state.merge(input) if input
      event = event.to_sym
      current_phase = state.phase

      ev_to_fire = if event == :resume
        # Find the first external event that can originate from the current wait state.
        name, = @external_events.find { |_, ts| ts.any? { |t| t[:from] == current_phase } }
        unless name
          raise ArgumentError,
            "No external event registered for wait state #{current_phase.inspect}"
        end
        name
      else
        unless @external_events.key?(event)
          raise ArgumentError,
            "Unknown event #{event.inspect}. Valid events: #{@external_events.keys.inspect}"
        end
        event
      end

      if Phronomy.configuration.event_loop
        run_via_event_loop(state,
          recursion_limit: Phronomy.configuration.recursion_limit,
          resume_event: ev_to_fire, resume_phase: current_phase)
      else
        run_workflow(state, resume_event: ev_to_fire, resume_phase: current_phase)
      end
    end

    # Streaming execution. Yields { state: Symbol, context: Object } after each state action completes.
    # @param input [Hash]
    # @param config [Hash]
    # @yield [Hash]
    # @return [Object] final context
    def stream(input, config: {}, &block)
      thread_id = config[:thread_id] || SecureRandom.uuid
      recursion_limit = config.fetch(:recursion_limit, Phronomy.configuration.recursion_limit)
      state = @state_class.new(**input)
      state.set_graph_metadata(thread_id: thread_id)
      run_workflow(state, recursion_limit: recursion_limit, &block)
    end

    private

    # Builds an FSMSession for the given context. Used in EventLoop mode.
    def build_session_for(context:, recursion_limit:, resume_event: nil, resume_phase: nil)
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
        resume_event: resume_event,
        resume_phase: resume_phase
      )
    end

    # Executes the workflow via the singleton EventLoop.
    # Blocks the calling thread on a completion queue until the workflow
    # finishes, halts at a wait state, or raises an error.
    def run_via_event_loop(context, recursion_limit:, resume_event: nil, resume_phase: nil)
      session = build_session_for(
        context: context, recursion_limit: recursion_limit,
        resume_event: resume_event, resume_phase: resume_phase
      )
      completion_queue = Phronomy::EventLoop.instance.register(session)
      result = completion_queue.pop
      raise result if result.is_a?(Exception)
      result
    end

    def run_workflow(ctx, resume_event: nil, resume_phase: nil, recursion_limit: 25, &event_block)
      if resume_event
        # -- Resume from a wait state -------------------------------------------
        # Fire the external event on a tracker positioned at the wait state.
        # state_machines will invoke before_transition (exit) and after_transition
        # (entry) callbacks as part of the transition, so both actions fire here.
        current_state = resume_phase
        tracker = new_phase_machine(current_state)
        tracker.context = ctx
        fire_event!(tracker, resume_event, current_state)
        ctx = tracker.context
        next_phase = tracker.phase.to_sym
        current_state = (next_phase == current_state) ? FINISH : next_phase
      else
        # -- Fresh start --------------------------------------------------------
        current_state = @entry_point
        tracker = new_phase_machine(current_state)
        tracker.context = ctx
        # state_machines only fires after_transition callbacks on transitions.
        # The entry point has no prior transition, so we invoke its entry actions directly.
        @entry_actions[current_state]&.each do |c|
          result = c.call(ctx)
          ctx = result if result.is_a?(Phronomy::WorkflowContext)
        end
        tracker.context = ctx
      end

      # Event queue: decouple action execution from transition firing.
      # Events are enqueued after visiting a state and processed at the top
      # of the next iteration so that guards always see the freshest context.
      event_queue = []
      step = 0

      loop do
        break if current_state == FINISH

        # -- Process next pending event -----------------------------------------
        # Dequeue one event and fire it against the state machine. Guards are
        # evaluated here (at fire time). Entry/exit callbacks fire inside fire_event!.
        if (event = event_queue.shift)
          if step >= recursion_limit
            raise Phronomy::RecursionLimitError,
              "Recursion limit (#{recursion_limit}) exceeded"
          end

          fire_event!(tracker, event, current_state)
          ctx = tracker.context
          next_phase = tracker.phase.to_sym
          # When next_phase == current_state no transition matched → terminal state.
          current_state = (next_phase == current_state) ? FINISH : next_phase
          step += 1
          next
        end

        # -- Queue empty: check for halt -----------------------------------------
        # Auto-halt at wait states: persist phase in context and return to caller.
        # The caller resumes via send_event.
        if @wait_state_names.include?(current_state)
          ctx.set_graph_metadata(thread_id: ctx.thread_id, phase: current_state)
          return ctx
        end

        # -- Validate state is known --------------------------------------------
        unless @declared_states.include?(current_state)
          raise ArgumentError, "State #{current_state.inspect} is not defined"
        end

        # -- Emit stream event and enqueue transition ---------------------------
        # Entry action for current_state has already been invoked (either by the
        # initial manual call above, or by the after_transition callback fired
        # inside fire_event! on the previous iteration).
        event_block&.call({state: current_state, context: ctx})

        # state_completed: unified event for all auto-fire transitions.
        # No enqueue:      terminal state — next iteration exits via FINISH check.
        if @auto_state_set.key?(current_state)
          event_queue << :state_completed
        else
          current_state = FINISH
        end
      end

      ctx.set_graph_metadata(thread_id: ctx.thread_id, phase: :__end__)
      ctx
    end

    # Fires +event_name+ on +tracker+, raising a descriptive error if no
    # transition matches. state_machines event methods return false when no
    # transition can be taken (invalid state or all guards fail).
    def fire_event!(tracker, event_name, from_state)
      return if tracker.send(event_name)

      raise ArgumentError,
        "Transition from #{from_state.inspect} via event #{event_name.inspect} failed. " \
        "Ensure at least one guard matches or add a fallback (no-guard) transition."
    end

    # Builds the PhaseTracker class backed by state_machines.
    #
    # Four event/callback types are registered:
    #   state_completed       — all auto-fire transitions (guarded and unguarded)
    #   <external_name>       — external events originating from wait states
    #   after_transition to   — entry callbacks (invoked when entering a state)
    #   before_transition from — exit callbacks (invoked when leaving a state)
    #
    # Guard lambdas bridge the PhaseTracker and WorkflowContext via +m.context+.
    def build_phase_machine_class(auto_transitions, exit_actions)
      entry = @entry_point
      all_states = (@declared_states + @wait_state_names + [:__end__]).uniq
      auto_trans = auto_transitions  # Array of { from:, to:, guard: }
      ext_events = @external_events
      entry_acts = @entry_actions
      exit_acts = exit_actions

      Class.new do
        # Holds the current WorkflowContext so guards and callbacks can read it.
        attr_accessor :context

        state_machine :phase, initial: entry do
          all_states.each { |s| state s }

          # Auto-fire transitions: all auto transitions unified under :state_completed.
          # Includes unguarded (unconditional) and guarded (conditional) transitions.
          # Declaration order is preserved; guards are evaluated before unguarded fallbacks.
          event :state_completed do
            auto_trans.each do |t|
              if t[:guard]
                guard_proc = t[:guard]
                transition t[:from] => t[:to], :if => ->(m) { guard_proc.call(m.context) }
              else
                transition t[:from] => t[:to]
              end
            end
          end

          # External events: human-in-the-loop triggers from wait states.
          ext_events.each do |ev_name, transitions|
            event ev_name do
              transitions.each do |t|
                if t[:guard]
                  guard_proc = t[:guard]
                  transition t[:from] => t[:to], :if => ->(m) { guard_proc.call(m.context) }
                else
                  transition t[:from] => t[:to]
                end
              end
            end
          end

          # Entry callbacks: fire after_transition into each state.
          #    Each callable is registered as a separate callback; state_machines
          #    accumulates them and fires in declaration order.
          #    If the callable returns a WorkflowContext (e.g. via s.merge(...)),
          #    the returned context replaces the current one on the tracker.
          entry_acts.each do |state_name, callables|
            callables.each do |callable|
              after_transition to: state_name do |machine|
                result = callable.call(machine.context)
                machine.context = result if result.is_a?(Phronomy::WorkflowContext)
              end
            end
          end

          # Exit callbacks: fire before_transition out of each state.
          #    Each callable is registered as a separate callback; state_machines
          #    accumulates them and fires in declaration order.
          exit_acts.each do |state_name, callables|
            callables.each do |callable|
              before_transition from: state_name do |machine|
                callable.call(machine.context)
              end
            end
          end
        end
      end
    rescue => e
      raise ArgumentError, "Failed to build phase machine: #{e.message}"
    end

    # Creates a PhaseTracker instance initialized to +from_state+.
    def new_phase_machine(from_state)
      machine = @phase_machine_class.new
      # Override the initial state set by state_machine's initializer so we can
      # resume from an arbitrary state (e.g. after a wait state).
      machine.instance_variable_set(:@phase, from_state.to_s)
      machine
    end
  end
end
