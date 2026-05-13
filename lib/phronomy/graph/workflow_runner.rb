# frozen_string_literal: true

require "securerandom"

module Phronomy
  module Graph
    # Execution engine for compiled graphs.
    # Manages node execution, phase transitions, halt/resume, and wait states.
    # Instantiated by StateGraph#compile and wrapped by CompiledGraph.
    #
    # Wait states (registered via StateGraph#add_wait_state) are virtual nodes
    # that automatically halt execution when reached. They can be resumed with
    # either #resume (generic) or #send_event (event-typed).
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
      end

      # Registers a callback to run before the given node executes.
      # Return :halt from the block to pause execution; any other value continues.
      # @param node [Symbol]
      # @yield [state]
      # @return [self]
      def interrupt_before(node, &block)
        @before_callbacks[node] = block
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

      # Resumes a halted graph from the state returned by a previous invoke/resume.
      #
      # For wait states (registered via add_wait_state), prefer #send_event for
      # event-typed resumption. This method also works as a generic resume.
      #
      # @param state [Object] halted context with current_nodes set
      # @param input [Hash, nil] optional field updates to merge before resuming
      # @return [Object] final context
      def resume(state:, input: nil)
        state = state.merge(input) if input

        current_phase = state.phase

        # Wait state registered via add_wait_state — use resume_to directly.
        if @wait_states.key?(current_phase)
          run_graph(state, from_node: @wait_states[current_phase][:resume_to],
            skip_first_before: false)

        # interrupt_before style halt — skip the before callback on resume.
        elsif state.halted_before
          raise ArgumentError, "State has no pending nodes to resume from" if state.current_nodes.empty?

          run_graph(state, from_node: state.current_nodes.first, skip_first_before: true)

        # interrupt_after or pending-at-finish — run from stored next node.
        else
          from_nodes = state.current_nodes
          raise ArgumentError, "State has no pending nodes to resume from" if from_nodes.nil? || from_nodes.empty?

          run_graph(state, from_node: from_nodes.first, skip_first_before: false)
        end
      end

      # Fires a named resume event to advance from a wait state.
      # The event must match the +resume_event:+ declared in add_wait_state.
      #
      # @param state [Object] halted context whose phase is the target wait state
      # @param event [Symbol] the resume event name declared in add_wait_state
      # @param input [Hash, nil] optional field updates to merge before resuming
      # @return [Object] final context
      def send_event(state:, event:, input: nil)
        state = state.merge(input) if input
        event = event.to_sym

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
        step = 0
        first_step = true

        while current_node && current_node != StateGraph::FINISH
          if step >= recursion_limit
            raise Phronomy::RecursionLimitError,
              "Recursion limit (#{recursion_limit}) exceeded"
          end

          # Auto-halt at wait states declared via add_wait_state.
          # The wait state name is stored in current_nodes so that #resume and
          # #send_event can look it up via state.phase.
          if @wait_states.key?(current_node)
            state.set_graph_metadata(
              thread_id: state.thread_id,
              current_nodes: [current_node],
              halted_before: false
            )
            state_store&.save(state)
            return state
          end

          # interrupt_before callback
          unless skip_first_before && first_step
            if (cb = @before_callbacks[current_node])
              if cb.call(state) == :halt
                state.set_graph_metadata(
                  thread_id: state.thread_id,
                  current_nodes: [current_node],
                  halted_before: true
                )
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
          if (cb = @after_callbacks[current_node])
            next_n = resolve_next_node(current_node, state)
            if cb.call(state) == :halt
              state.set_graph_metadata(
                thread_id: state.thread_id,
                current_nodes: [next_n].compact,
                halted_before: false
              )
              state_store&.save(state)
              return state
            end
            current_node = next_n
          else
            current_node = resolve_next_node(current_node, state)
          end

          step += 1
        end

        state.set_graph_metadata(
          thread_id: state.thread_id,
          current_nodes: [],
          halted_before: false
        )
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
    end
  end
end
