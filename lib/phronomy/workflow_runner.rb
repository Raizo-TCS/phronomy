# frozen_string_literal: true

require "securerandom"
require "state_machines"

module Phronomy
  # Execution engine for compiled workflows.
  # Manages node execution, phase transitions, halt/resume, and wait states.
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
  # == Three transition categories registered in PhaseTracker
  #
  #   1. advance_<from>  — automatic, unconditional after-transitions
  #                        fired when an action state's action completes
  #                        (declared with +after :foo, to: :bar+)
  #
  #   2. route           — a single event that carries all guarded transitions
  #                        (declared with +event :route, from: :foo, guard: ..., to: :bar+)
  #                        Guards are evaluated in declaration order; first match wins.
  #                        An unguarded fallback, if declared, is evaluated last.
  #
  #   3. <event_name>    — external events triggered by human input, originating
  #                        from wait states
  #                        (declared with +event :approve, from: :awaiting, to: :run+)
  class WorkflowRunner
    include Phronomy::Runnable

    # Sentinel value for the terminal state of a workflow.
    FINISH = :__end__

    def initialize(state_class:, nodes:, after_transitions:, route_transitions:,
      external_events:, entry_point:, wait_state_names: [],
      before_callbacks: {}, after_callbacks: {}, state_store: nil)
      @state_class = state_class
      @nodes = nodes
      @after_transitions = after_transitions  # { from => to }
      @route_transitions = route_transitions  # { from => [{guard:, to:}, ...] }
      @external_events = external_events    # { name => [{from:, to:, guard:}, ...] }
      @entry_point = entry_point
      @wait_state_names = wait_state_names
      @before_callbacks = before_callbacks.dup
      @after_callbacks = after_callbacks.dup
      @state_store_override = state_store
      @phase_machine_class = build_phase_machine_class
    end

    # Executes the workflow from the initial state.
    # @param input [Hash] initial context field values
    # @param config [Hash] { thread_id:, recursion_limit:, user_id:, session_id: }
    # @return [Object] final context (includes Phronomy::WorkflowContext)
    def invoke(input, config: {})
      caller_meta = {}
      caller_meta[:user_id] = config[:user_id] if config[:user_id]
      caller_meta[:session_id] = config[:session_id] if config[:session_id]

      trace("graph.invoke", input: input.inspect, **caller_meta) do |_span|
        thread_id = config[:thread_id] || SecureRandom.uuid
        recursion_limit = config.fetch(:recursion_limit, Phronomy.configuration.recursion_limit)
        state = @state_class.new(**input)
        state.set_graph_metadata(thread_id: thread_id)
        result = run_graph(state, recursion_limit: recursion_limit)
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

      tracker = new_phase_machine(current_phase)
      tracker.context = state

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

      fire_event!(tracker, ev_to_fire, current_phase)

      next_phase = tracker.phase.to_sym
      next_node = (next_phase == :__end__) ? FINISH : next_phase
      run_graph(state, from_node: next_node)
    end

    # Streaming execution. Yields { node: Symbol, state: Object } after each node completes.
    # @param input [Hash]
    # @param config [Hash]
    # @yield [Hash]
    # @return [Object] final context
    def stream(input, config: {}, &block)
      thread_id = config[:thread_id] || SecureRandom.uuid
      recursion_limit = config.fetch(:recursion_limit, Phronomy.configuration.recursion_limit)
      state = @state_class.new(**input)
      state.set_graph_metadata(thread_id: thread_id)
      run_graph(state, recursion_limit: recursion_limit, &block)
    end

    private

    def state_store
      @state_store_override || Phronomy.configuration.default_state_store
    end

    def run_graph(state, from_node: nil, recursion_limit: 25, &event_block)
      current_node = from_node || @entry_point
      tracker = new_phase_machine(current_node)
      tracker.context = state
      step = 0

      while current_node && current_node != FINISH
        if step >= recursion_limit
          raise Phronomy::RecursionLimitError,
            "Recursion limit (#{recursion_limit}) exceeded"
        end

        # Auto-halt at wait states: save context and return to caller.
        if @wait_state_names.include?(current_node)
          state.set_graph_metadata(thread_id: state.thread_id, phase: current_node)
          state_store&.save(state)
          return state
        end

        node_fn = @nodes[current_node]
        raise ArgumentError, "Node #{current_node.inspect} is not defined" unless node_fn

        result = node_fn.call(state)
        state = case result
        when Hash then state.merge(result)
        when @state_class then result
        when nil then state
        else
          raise ArgumentError,
            "Node #{current_node} returned #{result.class}; " \
            "expected Hash, #{@state_class}, or nil"
        end

        # Update tracker so guards see the freshest context.
        tracker.context = state

        event_block&.call({node: current_node, state: state})

        # Delegate transition decision to state_machines.
        if @after_transitions.key?(current_node)
          fire_event!(tracker, :"advance_#{current_node}", current_node)
        elsif @route_transitions.key?(current_node)
          ev_name = @route_transitions[current_node][:event_name]
          fire_event!(tracker, ev_name, current_node)
        end
        # Nodes with no declared outgoing transition are treated as terminal:
        # next_phase == current_node triggers the FINISH assignment below.

        next_phase = tracker.phase.to_sym
        # When next_phase == current_node: no transition fired (terminal node) → end.
        # When next_phase == :__end__ (== FINISH): route led to finish → exit loop.
        current_node = (next_phase == current_node) ? FINISH : next_phase

        step += 1
      end

      state.set_graph_metadata(thread_id: state.thread_id, phase: :__end__)
      state_store&.save(state)
      state
    end

    # Fires +event_name+ on +tracker+, raising a descriptive error if no
    # transition matches. state_machines event methods return false when no
    # transition can be taken (invalid state or all guards fail).
    def fire_event!(tracker, event_name, from_node)
      return if tracker.send(event_name)

      raise ArgumentError,
        "Transition from #{from_node.inspect} via event #{event_name.inspect} failed. " \
        "Ensure at least one guard matches or add a fallback (no-guard) transition."
    end

    # Builds the PhaseTracker class backed by state_machines.
    #
    # Three event types are registered:
    #   advance_<from>  — unconditional after-transitions
    #   route           — all guarded routing transitions (one event, multiple transitions)
    #   <external_name> — external events originating from wait states
    #
    # Guard lambdas bridge the PhaseTracker and WorkflowContext via +m.context+.
    def build_phase_machine_class
      entry = @entry_point
      all_states = (@nodes.keys + @wait_state_names + [:__end__]).uniq
      after_trans = @after_transitions   # { from => to }
      route_trans = @route_transitions   # { from => [{guard:, to:}, ...] }
      ext_events = @external_events     # { name => [{from:, to:, guard:}, ...] }

      Class.new do
        # Holds the current WorkflowContext so guards can read it.
        attr_accessor :context

        state_machine :phase, initial: entry do
          all_states.each { |s| state s }

          # 1. After-transitions: unconditional, fire on action completion.
          after_trans.each do |from, to|
            event :"advance_#{from}" do
              transition from => to
            end
          end

          # 2. Route events: one named event per from-state (name may vary).
          #    Declaration order is preserved; guards first, unguarded fallback last.
          route_trans.each do |from, routing|
            event routing[:event_name] do
              routing[:entries].each do |t|
                if t[:guard]
                  guard_proc = t[:guard]
                  transition from => t[:to], :if => ->(m) { guard_proc.call(m.context) }
                else
                  transition from => t[:to]
                end
              end
            end
          end

          # 3. External events: human-in-the-loop triggers from wait states.
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
        end
      end
    rescue => e
      raise ArgumentError, "Failed to build phase machine: #{e.message}"
    end

    # Creates a PhaseTracker instance initialized to +from_node+.
    def new_phase_machine(from_node)
      machine = @phase_machine_class.new
      # Override the initial state set by state_machine's initializer so we can
      # resume from an arbitrary node (e.g. after a wait state).
      machine.instance_variable_set(:@phase, from_node.to_s)
      machine
    end
  end
end
