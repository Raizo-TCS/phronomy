# frozen_string_literal: true

module Phronomy
  module Graph
    # Declarative agent workflow definition class.
    # Assembles nodes and edges, then returns an executable CompiledGraph via compile.
    class StateGraph
      START = :__start__
      FINISH = :__end__

      attr_reader :nodes, :edges, :entry_point

      # @param state_class [Class] class that includes Phronomy::Graph::State
      def initialize(state_class)
        @state_class = state_class
        @nodes = {}
        @edges = {}
        @conditional_edges = {}
        @entry_point = nil
        @before_callbacks = {}
        @after_callbacks = {}
      end

      # Adds a node.
      # @param name [Symbol]
      # @param callable [#call, nil] node execution logic (block accepted)
      # @return [self]
      def add_node(name, callable = nil, &block)
        @nodes[name] = callable || block
        self
      end

      # Adds a directed edge.
      # @param from [Symbol]
      # @param to [Symbol]
      # @param condition [Proc, nil] guard condition — receives state and returns truthy/falsy.
      #   When nil, the edge is unconditional. When multiple edges exist from the same node,
      #   they are evaluated in registration order and the first matching edge is taken.
      # @return [self]
      def add_edge(from, to, condition = nil)
        @edges[from] ||= []
        @edges[from] << {to: to, condition: condition}
        self
      end

      # Adds a conditional edge.
      # @param from [Symbol]
      # @param condition [Proc] receives state and returns the next node name
      # @param mapping [Hash, nil] maps condition return value to a node name (optional)
      # @return [self]
      def add_conditional_edges(from, condition, mapping = nil)
        @conditional_edges[from] = {condition: condition, mapping: mapping}
        self
      end

      # Sets the entry point node.
      # @param node_name [Symbol]
      # @return [self]
      def set_entry_point(node_name)
        @entry_point = node_name
        self
      end

      # Registers a callback to run before the given node executes.
      # Return :halt from the block to pause execution; any other value continues.
      # Callbacks registered here become defaults for every CompiledGraph produced by compile.
      # @param node [Symbol]
      # @yield [state] the current state
      # @return [self]
      def interrupt_before(node, &block)
        @before_callbacks[node] = block
        self
      end

      # Registers a callback to run after the given node completes.
      # Return :halt from the block to pause execution; any other value continues.
      # Callbacks registered here become defaults for every CompiledGraph produced by compile.
      # @param node [Symbol]
      # @yield [state] the state after the node ran
      # @return [self]
      def interrupt_after(node, &block)
        @after_callbacks[node] = block
        self
      end

      # Adds a parallel node that executes multiple branches concurrently.
      # Each branch callable receives the current state and must return a Hash or nil.
      # Results are merged in registration order (see ParallelNode for merge policy).
      #
      # @param name     [Symbol]
      # @param branches [Array<#call>]    at least one callable required
      # @param timeout  [Numeric, nil]   wall-clock limit in seconds (nil = unlimited)
      # @param on_error [Symbol]         :raise (default) or :best_effort
      # @return [self]
      def add_parallel_node(name, *branches, timeout: nil, on_error: :raise)
        raise ArgumentError, "add_parallel_node requires at least one branch" if branches.empty?

        @nodes[name] = ParallelNode.new(branches, timeout: timeout, on_error: on_error)
        self
      end

      # Embeds a compiled subgraph as a single node in this graph.
      # The subgraph is invoked with a Hash derived from the parent state;
      # its final state Hash is returned and merged into the parent state.
      #
      # @param name [Symbol]
      # @param subgraph [CompiledGraph] the compiled subgraph to embed
      # @param input_mapper  [Proc, nil] maps parent state → input Hash for the subgraph;
      #   defaults to state.to_h (passes all parent fields)
      # @param output_mapper [Proc, nil] maps subgraph final state → Hash to merge back;
      #   defaults to sub_state.to_h (passes all subgraph fields)
      # @return [self]
      def add_subgraph(name, subgraph, input_mapper: nil, output_mapper: nil)
        add_node(name) do |state|
          input = input_mapper ? input_mapper.call(state) : state.to_h
          sub_thread_id = "#{state.thread_id}/#{name}"
          sub_state = subgraph.invoke(input, config: {thread_id: sub_thread_id})
          output_mapper ? output_mapper.call(sub_state) : sub_state.to_h
        end
      end

      # Compiles the graph and returns a CompiledGraph.
      # Callbacks registered on StateGraph are inherited; additional callbacks can be
      # registered on the returned CompiledGraph to override or extend them.
      # @param state_store [Phronomy::StateStore::Base, nil] optional state store
      #   to use for this compiled graph, overriding the global default.
      # @return [CompiledGraph]
      def compile(state_store: nil)
        if @entry_point.nil? && @nodes.size > 1
          raise ArgumentError,
            "set_entry_point was not called; call set_entry_point(:node_name) " \
            "before compile when the graph has multiple nodes"
        end
        CompiledGraph.new(
          state_class: @state_class,
          nodes: @nodes,
          edges: @edges,
          conditional_edges: @conditional_edges,
          entry_point: @entry_point || @nodes.keys.first,
          before_callbacks: @before_callbacks.dup,
          after_callbacks: @after_callbacks.dup,
          state_store: state_store
        )
      end

      attr_reader :conditional_edges
    end
  end
end
