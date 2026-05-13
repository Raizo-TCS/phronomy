# frozen_string_literal: true

module Phronomy
  module Graph
    # Declarative agent workflow definition class.
    # Assembles nodes and edges, then returns an executable CompiledGraph via compile.
    class StateGraph
      START = :__start__
      FINISH = :__end__

      attr_reader :nodes, :edges, :entry_point

      # @param state_class [Class] class that includes Phronomy::Graph::Context
      def initialize(state_class)
        @state_class = state_class
        @nodes = {}
        @edges = {}
        @conditional_edges = {}
        @entry_point = nil
        @before_callbacks = {}
        @after_callbacks = {}
        @wait_states = {}
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
      # Registers a callback to run before the given node executes.
      # Return :halt from the block to pause execution; any other value continues.
      # When called without a block, execution always halts before the node.
      # Callbacks registered here become defaults for every CompiledGraph produced by compile.
      # @param node [Symbol]
      # @yield [state] optional — omit to always halt
      # @return [self]
      def interrupt_before(node, &block)
        @before_callbacks[node] = block || ->(_) { :halt }
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

      # Declares a named wait state that automatically halts execution when reached.
      # The graph edge from +after:+ to this wait state is added automatically.
      # To resume, call either +compiled.resume(state:)+ (generic) or
      # +compiled.send_event(state:, event: resume_event)+ (event-typed).
      #
      # Convention: name the wait state +:awaiting_<before_node>+ so that
      # +state.phase+ reflects the intent (e.g. +:awaiting_run_checks+).
      #
      # @param name [Symbol] wait state identifier (e.g. :awaiting_run_checks)
      # @param resume_event [Symbol] event name accepted by #send_event
      # @param after [Symbol] node that flows into this wait state
      # @param before [Symbol] node to execute after the wait state is resolved
      # @return [self]
      def add_wait_state(name, resume_event:, after:, before:)
        name = name.to_sym
        @wait_states[name] = {resume_event: resume_event.to_sym, resume_to: before.to_sym}
        add_edge(after, name)
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
          wait_states: @wait_states.dup,
          state_store: state_store
        )
      end

      attr_reader :conditional_edges
    end
  end
end
