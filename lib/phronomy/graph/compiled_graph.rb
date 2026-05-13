# frozen_string_literal: true

module Phronomy
  module Graph
    # Executable graph produced by StateGraph#compile.
    # Wraps a WorkflowRunner and exposes the public execution API.
    # Includes Runnable so it can be embedded in a larger pipeline.
    class CompiledGraph
      include Phronomy::Runnable

      def initialize(state_class:, nodes:, edges:, conditional_edges:, entry_point:,
        before_callbacks: {}, after_callbacks: {}, wait_states: {}, state_store: nil)
        @runner = WorkflowRunner.new(
          state_class: state_class,
          nodes: nodes,
          edges: edges,
          conditional_edges: conditional_edges,
          entry_point: entry_point,
          before_callbacks: before_callbacks,
          after_callbacks: after_callbacks,
          wait_states: wait_states,
          state_store: state_store
        )
      end

      # Registers a callback to run before the given node executes.
      # Return :halt from the block to pause execution; any other value continues.
      # @param node [Symbol]
      # @yield [state]
      # @return [self]
      def interrupt_before(node, &block)
        @runner.interrupt_before(node, &block)
        self
      end

      # Registers a callback to run after the given node completes.
      # Return :halt from the block to pause execution; any other value continues.
      # @param node [Symbol]
      # @yield [state]
      # @return [self]
      def interrupt_after(node, &block)
        @runner.interrupt_after(node, &block)
        self
      end

      # Executes the graph from the entry point.
      # @param input [Hash] initial context field values
      # @param config [Hash] { thread_id:, recursion_limit:, user_id:, session_id: }
      # @return [Object] final context
      def invoke(input, config: {})
        @runner.invoke(input, config: config)
      end

      # Resumes a halted graph from the state returned by a previous invoke/resume.
      # @param state [Object] halted context with current_nodes set
      # @param input [Hash, nil] optional field updates to merge before resuming
      # @return [Object] final context
      def resume(state:, input: nil)
        @runner.resume(state: state, input: input)
      end

      # Fires a named resume event to advance from a wait state.
      # The event must match the +resume_event:+ declared in StateGraph#add_wait_state.
      # @param state [Object] halted context whose phase is the target wait state
      # @param event [Symbol] the resume event name
      # @param input [Hash, nil] optional field updates to merge before resuming
      # @return [Object] final context
      def send_event(state:, event:, input: nil)
        @runner.send_event(state: state, event: event, input: input)
      end

      # Streaming execution. Yields { node: Symbol, state: Object } after each node.
      # @param input [Hash]
      # @param config [Hash]
      # @yield [Hash]
      # @return [Object] final context
      def stream(input, config: {}, &block)
        @runner.stream(input, config: config, &block)
      end
    end
  end
end


