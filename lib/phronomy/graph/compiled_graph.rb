# frozen_string_literal: true

require "securerandom"

module Phronomy
  module Graph
    # Executable graph produced by StateGraph#compile.
    # Includes Runnable so it can be embedded in a larger pipeline.
    class CompiledGraph
      include Phronomy::Runnable

      def initialize(state_class:, nodes:, edges:, conditional_edges:, entry_point:,
        before_callbacks: {}, after_callbacks: {}, state_store: nil)
        @state_class = state_class
        @nodes = nodes
        @edges = edges
        @conditional_edges = conditional_edges
        @entry_point = entry_point
        @before_callbacks = before_callbacks
        @after_callbacks = after_callbacks
        @state_store_override = state_store
      end

      # Registers a callback to run before the given node executes.
      # Return :halt from the block to pause execution; any other value continues.
      # @param node [Symbol]
      # @yield [state] the current state
      # @return [self]
      def interrupt_before(node, &block)
        @before_callbacks[node] = block
        self
      end

      # Registers a callback to run after the given node completes.
      # Return :halt from the block to pause execution; any other value continues.
      # @param node [Symbol]
      # @yield [state] the state after the node ran
      # @return [self]
      def interrupt_after(node, &block)
        @after_callbacks[node] = block
        self
      end

      # Executes the graph from the entry point.
      # Automatically assigns a thread_id if not supplied via config.
      # @param input [Hash] initial state field values
      # @param config [Hash] { thread_id: String, recursion_limit: Integer,
      #   user_id: String (optional), session_id: String (optional) }
      # @return [Object] final state (includes Phronomy::Graph::State)
      def invoke(input, config: {})
        caller_meta = {}
        caller_meta[:user_id] = config[:user_id] if config[:user_id]
        caller_meta[:session_id] = config[:session_id] if config[:session_id]

        trace("graph.invoke", input: input.inspect, **caller_meta) do |_span|
          thread_id = config[:thread_id] || SecureRandom.uuid
          recursion_limit = config.fetch(:recursion_limit, Phronomy.configuration.recursion_limit)
          state = @state_class.new(**input)
          state.set_graph_metadata(thread_id: thread_id, current_nodes: [], halted_before: false)
          result = execute_graph(state, recursion_limit: recursion_limit)
          [result, nil]
        end
      end

      # Resumes a halted graph from the state returned by a previous invoke/resume.
      # @param state [Object] state object (includes Phronomy::Graph::State) with current_nodes set
      # @param input [Hash, nil] optional field updates to merge before resuming
      # @return [Object] final state
      def resume(state:, input: nil)
        state = state.merge(input) if input
        from_nodes = state.current_nodes
        raise ArgumentError, "State has no pending nodes to resume from" if from_nodes.nil? || from_nodes.empty?

        execute_graph(state, from_node: from_nodes.first,
          skip_first_before: state.halted_before)
      end

      # Streaming execution. Yields { node: Symbol, state: State } after each node completes.
      # @param input [Hash]
      # @param config [Hash]
      # @yield [Hash] { node: Symbol, state: State }
      # @return [Object] final state
      def stream(input, config: {}, &block)
        thread_id = config[:thread_id] || SecureRandom.uuid
        recursion_limit = config.fetch(:recursion_limit, Phronomy.configuration.recursion_limit)
        state = @state_class.new(**input)
        state.set_graph_metadata(thread_id: thread_id, current_nodes: [], halted_before: false)
        execute_graph(state, recursion_limit: recursion_limit, &block)
      end

      private

      def state_store
        @state_store_override || Phronomy.configuration.default_state_store
      end

      def execute_graph(state, from_node: nil, recursion_limit: 25,
        skip_first_before: false, &event_block)
        current_node = from_node || @entry_point
        step = 0
        first_step = true

        while current_node && current_node != StateGraph::FINISH
          if step >= recursion_limit
            raise Phronomy::RecursionLimitError,
              "Recursion limit (#{recursion_limit}) exceeded"
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
            next_n = next_node(current_node, state)
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
            current_node = next_node(current_node, state)
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

      def next_node(current, state)
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
