# frozen_string_literal: true

require "securerandom"
require "state_machines"

module Phronomy
  module Graph
    # Execution engine for compiled graphs.
    # Manages node execution, phase transitions, halt/resume, and wait states.
    # Instantiated by StateGraph#compile and wrapped by CompiledGraph.
    #
    # Wait states (registered via StateGraph#add_wait_state) are virtual nodes
    # that automatically halt execution when reached. They can be resumed with
    # either #resume (generic) or #send_event (event-typed).
    #
    # Internally, a state_machines-based PhaseTracker class is generated at
    # initialization time. The tracker validates phase transitions during
    # execution; invalid transitions are logged as warnings without halting.
    class WorkflowRunner
      include Phronomy::Runnable

      def initialize(state_class:, nodes:, edges:, conditional_edges:, entry_point:,
        before_callbacks: {}, after_callbacks: {}, wait_states: {}, state_store: nil)
        @state_class = state_class
        @nodes = nodes
        @edges = edges
        @conditional_edges = conditional_edges
        @entry_point = entry_point
        @before_callbacks = before_callbacks.dup
        @after_callbacks = after_callbacks.dup
        # { wait_state_name => { resume_event: Symbol, resume_to: Symbol } }
        @wait_states = wait_states.dup
        @state_store_override = state_store
        @phase_machine_class = build_phase_machine_class
      end

      # Registers a callback to run before the given node executes.
      # Return :halt from the block to pause execution; any other value continues.
      # When called without a block, execution always halts before the node.
      # @param node [Symbol]
      # @yield [state] optional — omit to always halt
      # @return [self]
      def interrupt_before(node, &block)
        @before_callbacks[node] = block || ->(_) { :halt }
        self
      end

      # Registers a callback to run after the given node completes.
      # Return :halt from the block to pause execution; any other value continues.
      # @param node [Symbol]
      # @yield [state]
      # @return [self]
      def interrupt_after(node, &block)
        @after_callbacks[node] = block
        self
      end

      # Executes the graph from the entry point.
      # @param input [Hash] initial context field values
      # @param config [Hash] { thread_id:, recursion_limit:, user_id:, session_id: }
      # @return [Object] final context (includes Phronomy::Graph::Context)
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

      # Generic resume. Routes based on the current phase encoding.
      # Equivalent to +send_event(state:, event: :resume, input:)+.
      #
      # @param state [Object] halted context
      # @param input [Hash, nil] optional field updates to merge before resuming
      # @return [Object] final context
      def resume(state:, input: nil)
        send_event(state: state, event: :resume, input: input)
      end

      # Fires a named event to advance a halted graph.
      #
      # The special event +:resume+ is accepted for all halt types:
      # - Named wait state (add_wait_state)  → resumes at +resume_to+ node
      # - interrupt_before style halt        → resumes at the halted node, skipping
      #                                        the before callback
      # - interrupt_after / finish-boundary  → resumes at the stored next node
      #
      # Any other event name must match the +resume_event:+ declared in
      # +StateGraph#add_wait_state+.
      #
      # @param state [Object] halted context
      # @param event [Symbol] +:resume+ for generic resumption, or a named event
      # @param input [Hash, nil] optional field updates to merge before resuming
      # @return [Object] final context
      def send_event(state:, event:, input: nil)
        state = state.merge(input) if input
        event = event.to_sym
        current_phase = state.phase

        if event == :resume
          # Named wait state: use resume_to
          if @wait_states.key?(current_phase)
            return run_graph(state, from_node: @wait_states[current_phase][:resume_to])
          end

          # interrupt_before style: phase is :awaiting_X, skip before callback on resume
          if state.halted_before
            node = current_phase.to_s.delete_prefix("awaiting_").to_sym
            raise ArgumentError, "State has no pending nodes to resume from" unless @nodes.key?(node)
            return run_graph(state, from_node: node, skip_first_before: true)
          end

          # interrupt_after / finish-boundary: resume from stored next node
          from_nodes = state.current_nodes
          raise ArgumentError, "State has no pending nodes to resume from" if from_nodes.nil? || from_nodes.empty?
          return run_graph(state, from_node: from_nodes.first)
        end

        # Named event lookup
        _, wait_cfg = @wait_states.find { |_, c| c[:resume_event] == event }
        unless wait_cfg
          valid = @wait_states.values.filter_map { |c| c[:resume_event] }.uniq
          raise ArgumentError, "Unknown event #{event.inspect}. Valid events: #{valid.inspect}"
        end
        run_graph(state, from_node: wait_cfg[:resume_to], skip_first_before: false)
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

      def run_graph(state, from_node: nil, recursion_limit: 25,
        skip_first_before: false, &event_block)
        current_node = from_node || @entry_point
        tracker = new_phase_machine(current_node)
        step = 0
        first_step = true

        while current_node && current_node != StateGraph::FINISH
          if step >= recursion_limit
            raise Phronomy::RecursionLimitError,
              "Recursion limit (#{recursion_limit}) exceeded"
          end

          # Auto-halt at wait states declared via add_wait_state.
          # The wait state name becomes the phase directly so that #resume and
          # #send_event can look it up via state.phase.
          if @wait_states.key?(current_node)
            state.set_graph_metadata(thread_id: state.thread_id, phase: current_node)
            state_store&.save(state)
            return state
          end

          # interrupt_before callback
          unless skip_first_before && first_step
            if (cb = @before_callbacks[current_node])
              if cb.call(state) == :halt
                halt_phase = :"awaiting_#{current_node}"
                advance_phase(tracker, current_node, halt_phase)
                state.set_graph_metadata(thread_id: state.thread_id, phase: halt_phase)
                state_store&.save(state)
                return state
              end
            end
          end
          first_step = false

          node_fn = @nodes[current_node]
          raise ArgumentError, "Node #{current_node} is not defined" unless node_fn

          result = node_fn.call(state)
          state = case result
          when Hash then state.merge(result)
          when @state_class then result
          when nil then state
          else
            raise ArgumentError,
              "Node #{current_node} returned #{result.class}; expected Hash, #{@state_class}, or nil"
          end

          event_block&.call({node: current_node, state: state})

          # interrupt_after callback
          next_n = resolve_next_node(current_node, state)
          if (cb = @after_callbacks[current_node]) && cb.call(state) == :halt
            # When next_n is FINISH (or nil), use :__at_finish__ so that the
            # context signals "halted at finish boundary" rather than "completed".
            halt_phase = (next_n.nil? || next_n == StateGraph::FINISH) ? :__at_finish__ : next_n
            advance_phase(tracker, current_node, halt_phase)
            state.set_graph_metadata(thread_id: state.thread_id, phase: halt_phase)
            state_store&.save(state)
            return state
          end
          advance_phase(tracker, current_node, next_n || StateGraph::FINISH)
          current_node = next_n

          step += 1
        end

        state.set_graph_metadata(thread_id: state.thread_id, phase: :__end__)
        state_store&.save(state)
        state
      end

      def resolve_next_node(current, state)
        if (cond = @conditional_edges[current])
          result = cond[:condition].call(state)
          if cond[:mapping]
            unless cond[:mapping].key?(result)
              raise ArgumentError,
                "Conditional edge from #{current.inspect} returned #{result.inspect}, " \
                "which is not present in the mapping (#{cond[:mapping].keys.inspect})"
            end
            return cond[:mapping][result]
          end
          return result
        end

        edges = @edges[current]
        return nil unless edges&.any?

        matched = edges.find { |edge| edge[:condition].nil? || edge[:condition].call(state) }
        matched&.fetch(:to)
      end

      # Builds a state_machines-based PhaseTracker class encoding the graph topology.
      # Returns nil if the build fails (execution continues without phase validation).
      def build_phase_machine_class
        entry = @entry_point
        nodes = @nodes.keys
        ws_names = @wait_states.keys
        awaiting = nodes.map { |n| :"awaiting_#{n}" }

        # Collect all valid (from, to) pairs; use a Hash to deduplicate.
        trans = {}

        @edges.each do |from, edge_list|
          edge_list.each do |edge|
            to = (edge[:to] == StateGraph::FINISH) ? :__end__ : edge[:to]
            trans[[from, to]] = true
          end
        end

        @conditional_edges.each do |from, cfg|
          targets = cfg[:mapping] ? cfg[:mapping].values : (nodes + ws_names + [:__end__])
          targets.each do |to|
            t = (to == StateGraph::FINISH) ? :__end__ : to
            trans[[from, t]] = true
          end
        end

        # Any node can be terminal (no outgoing edge = implicit advance to :__end__).
        nodes.each { |n| trans[[n, :__end__]] = true }

        # Any node can also halt at the finish boundary (interrupt_after on last step).
        nodes.each { |n| trans[[n, :__at_finish__]] = true }
        # Resuming from :__at_finish__ completes the graph.
        trans[[:__at_finish__, :__end__]] = true

        # interrupt_before: node ↔ awaiting_node
        nodes.each do |n|
          trans[[n, :"awaiting_#{n}"]] = true
          trans[[:"awaiting_#{n}", n]] = true
        end

        all_states = (nodes + ws_names + awaiting + [:__end__, :__at_finish__]).uniq
        trans_pairs = trans.keys

        Class.new do
          state_machine :phase, initial: entry do
            all_states.each { |s| state s }
            trans_pairs.each do |from, to|
              event :"advance_#{from}_to_#{to}" do
                transition from => to
              end
            end
          end
        end
      rescue => e
        warn "[Phronomy] Could not build phase machine: #{e.message}"
        nil
      end

      # Creates a PhaseTracker instance initialised to +from_node+.
      # Teleports the machine state directly (bypasses transition hooks) to
      # support resumption mid-graph without replaying history.
      def new_phase_machine(from_node)
        return nil unless @phase_machine_class && from_node

        machine = @phase_machine_class.new
        # state_machines stores state as a String in the instance variable.
        machine.instance_variable_set(:@phase, from_node.to_s)
        machine
      rescue => e
        warn "[Phronomy] Phase machine init failed: #{e.message}"
        nil
      end

      # Fires a transition event on the tracker from +from+ to +to+.
      # Logs a warning if the transition is not declared; does not raise.
      def advance_phase(tracker, from, to)
        return unless tracker && from

        to_sym = case to
        when nil, StateGraph::FINISH then :__end__
        else to
        end
        event_name = :"advance_#{from}_to_#{to_sym}"
        unless tracker.fire_events(event_name)
          warn "[Phronomy] Unexpected phase transition #{from.inspect} → #{to_sym.inspect}"
        end
      rescue => e
        warn "[Phronomy] Phase tracker error (#{from}→#{to}): #{e.message}"
      end
    end
  end
end
