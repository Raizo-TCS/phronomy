# frozen_string_literal: true

module Phronomy
  module Graph
    # Executable graph produced by StateGraph#compile.
    # Includes Runnable so it can be embedded in a Chain.
    class CompiledGraph
      include Phronomy::Runnable

      def initialize(state_class:, nodes:, edges:, conditional_edges:,
        entry_point:, checkpointer:, interrupt_before:, interrupt_after:)
        @state_class = state_class
        @nodes = nodes
        @edges = edges
        @conditional_edges = conditional_edges
        @entry_point = entry_point
        @checkpointer = checkpointer
        @interrupt_before = interrupt_before
        @interrupt_after = interrupt_after
      end

      # Executes the graph.
      # @param input [Hash] initial state field values
      # @param config [Hash] { thread_id:, recursion_limit: }
      # @return [Phronomy::Graph::State] final state
      def invoke(input, config: {})
        thread_id = config[:thread_id]
        recursion_limit = config.fetch(:recursion_limit, Phronomy.configuration.recursion_limit)

        state = if @checkpointer && thread_id
          checkpoint = @checkpointer.load(thread_id)
          checkpoint ? checkpoint.state : @state_class.new(**input)
        else
          @state_class.new(**input)
        end

        execute_graph(state, thread_id: thread_id, recursion_limit: recursion_limit)
      rescue Phronomy::Interrupt => e
        @checkpointer&.save(thread_id, e.state, interrupted_at: e.node)
        raise
      end

      # Resumes an interrupted graph.
      # @param thread_id [String]
      # @param input [Hash, nil] additional input (nil to continue from saved state)
      # @return [Phronomy::Graph::State]
      def resume(thread_id:, input: nil)
        raise ArgumentError, "Checkpointer is not configured" unless @checkpointer

        checkpoint = @checkpointer.load(thread_id)
        raise ArgumentError, "No checkpoint found for thread #{thread_id}" unless checkpoint

        state = input ? checkpoint.state.merge(input) : checkpoint.state
        # Pass skip_first_interrupt: true so that the node stored in interrupted_at
        # is not immediately re-interrupted by the same interrupt_before rule.
        execute_graph(state, from_node: checkpoint.interrupted_at, thread_id: thread_id,
          skip_first_interrupt: true)
      end

      # Streaming execution. Yields { node:, state: } after each node completes.
      # @param input [Hash]
      # @param config [Hash]
      # @yield [Hash] { node: Symbol, state: State }
      # @return [Phronomy::Graph::State]
      def stream(input, config: {}, &block)
        thread_id = config[:thread_id]
        recursion_limit = config.fetch(:recursion_limit, Phronomy.configuration.recursion_limit)
        state = @state_class.new(**input)
        execute_graph(state, thread_id: thread_id, recursion_limit: recursion_limit, &block)
      end

      private

      def execute_graph(state, from_node: nil, thread_id: nil, recursion_limit: 25,
        skip_first_interrupt: false, &event_block)
        current_node = from_node || @entry_point
        step = 0
        first_step = true

        while current_node && current_node != StateGraph::FINISH
          if step >= recursion_limit
            raise Phronomy::RecursionLimitError,
              "Recursion limit (#{recursion_limit}) exceeded"
          end

          unless skip_first_interrupt && first_step
            if @interrupt_before.include?(current_node)
              raise Phronomy::Interrupt.new(node: current_node, state: state)
            end
          end
          first_step = false

          node_fn = @nodes[current_node]
          raise ArgumentError, "Node #{current_node} is not defined" unless node_fn

          updates = node_fn.call(state)
          state = state.merge(updates) if updates.is_a?(Hash)

          @checkpointer&.save(thread_id, state, completed_node: current_node)

          event_block&.call({node: current_node, state: state})

          if @interrupt_after.include?(current_node)
            raise Phronomy::Interrupt.new(node: current_node, state: state)
          end

          current_node = next_node(current_node, state)
          step += 1
        end

        state
      end

      def next_node(current, state)
        if (cond = @conditional_edges[current])
          result = cond[:condition].call(state)
          return cond[:mapping] ? cond[:mapping][result] : result
        end

        edges = @edges[current]
        return nil unless edges&.any?

        edges.first
      end
    end
  end
end
