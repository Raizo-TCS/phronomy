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

      # Compiles the graph and returns a CompiledGraph.
      # @return [CompiledGraph]
      def compile
        CompiledGraph.new(
          state_class: @state_class,
          nodes: @nodes,
          edges: @edges,
          conditional_edges: @conditional_edges,
          entry_point: @entry_point || @nodes.keys.first
        )
      end

      attr_reader :conditional_edges
    end
  end
end
