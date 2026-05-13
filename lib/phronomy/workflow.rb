# frozen_string_literal: true

require_relative "workflow_runner"
require_relative "runnable"

module Phronomy
  # StateChart-style workflow definition DSL.
  #
  # Defines agent workflows in terms of *states* and *events* backed by
  # Phronomy::WorkflowRunner. This is the primary high-level API
  # for graph-based execution in phronomy.
  #
  # == Basic usage
  #
  #   app = Phronomy::Workflow.define(MyContext) do
  #     initial :fetch
  #
  #     state :fetch,   action: FETCH_NODE
  #     state :process, action: PROCESS_NODE
  #
  #     after :fetch,   to: :process
  #     after :process, to: :__finish__
  #   end
  #
  #   result = app.invoke({ url: "https://example.com" })
  #
  # == Wait states
  #
  #   app = Phronomy::Workflow.define(MyContext) do
  #     initial :propose
  #
  #     state :propose, action: PROPOSE_NODE
  #     wait_state :awaiting_approval
  #     state :execute, action: EXECUTE_NODE
  #
  #     after :propose, to: :awaiting_approval
  #     after :execute, to: :__finish__
  #
  #     event :approve, from: :awaiting_approval, to: :execute
  #     event :reject,  from: :awaiting_approval, to: :propose
  #   end
  #
  #   halted = app.invoke({ ... })
  #   final  = app.send_event(state: halted, event: :approve)
  #
  # == Conditional transitions
  #
  #   event :route, from: :decide, guard: ->(s) { s.score > 5 }, to: :high
  #   event :route, from: :decide, to: :low   # fallback (no guard)
  #
  class Workflow
    include Phronomy::Runnable

    # Defines a new Workflow.
    # @param context_class [Class] class that includes Phronomy::WorkflowContext
    # @yield block evaluated in DSL context
    # @return [Phronomy::Workflow] compiled and ready-to-run workflow instance
    def self.define(context_class, &block)
      builder = Builder.new(context_class)
      builder.instance_eval(&block)
      builder.build
    end

    # @param runner [Phronomy::WorkflowRunner]
    def initialize(runner)
      @runner = runner
    end

    # Executes the workflow from the initial state.
    # @param input [Hash] initial context field values
    # @param config [Hash] { thread_id:, recursion_limit:, user_id:, session_id: }
    # @return [Object] final context
    def invoke(input, config: {})
      @runner.invoke(input, config: config)
    end

    # Resumes a halted workflow. Generic resume that works for all halt types.
    # @param state [Object] halted context
    # @param input [Hash, nil] optional field updates to merge before resuming
    # @return [Object] final context
    def resume(state:, input: nil)
      @runner.resume(state: state, input: input)
    end

    # Fires a named event to advance a halted workflow.
    # @param state [Object] halted context
    # @param event [Symbol] event name (e.g. :approve, :reject, :resume)
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

    # ---------------------------------------------------------------------------
    # Internal DSL builder
    # ---------------------------------------------------------------------------

    # DSL builder for Phronomy::Workflow.define.
    # Collects state/event/transition declarations and produces a WorkflowRunner.
    class Builder
      FINISH = Phronomy::WorkflowRunner::FINISH

      def initialize(context_class)
        @context_class = context_class
        @initial = nil
        # { node_name => callable }
        @states = {}
        # Array of { from:, to: } — auto-transitions after a state action
        @after_transitions = []
        # Array of { name:, from:, to:, guard: } — event-driven transitions
        @event_transitions = []
        # Set of wait state names
        @wait_state_names = []
      end

      # Declares the initial (entry) state.
      # @param state_name [Symbol]
      # rubocop:disable Style/TrivialAccessors
      def initial(state_name)
        @initial = state_name
      end
      # rubocop:enable Style/TrivialAccessors

      # Declares an action state.
      # @param name [Symbol] state name
      # @param action [#call, nil] callable invoked when entering the state.
      #   If nil, the state is treated as a no-op pass-through.
      def state(name, action: nil)
        @states[name] = action || ->(s) { s }
      end

      # Declares a wait state that automatically halts execution when reached.
      # No action is registered; the workflow pauses here until an event resumes it.
      # @param name [Symbol] wait state name (conventionally :awaiting_something)
      def wait_state(name)
        @wait_state_names << name
      end

      # Declares an automatic transition that fires after a state's action completes.
      # @param from [Symbol] source state name
      # @param to [Symbol] destination state name or :__finish__
      def after(from, to:)
        dest = (to == :__finish__) ? FINISH : to
        @after_transitions << {from: from, to: dest}
      end

      # Declares an event-driven transition.
      # When +guard:+ is provided, the transition is taken only if the guard
      # returns truthy for the current context. Multiple events with the same
      # name and source are evaluated in declaration order; the first passing
      # guard wins.
      # @param name [Symbol] event name
      # @param from [Symbol] source state where this event can be fired
      # @param to [Symbol] destination state or :__finish__
      # @param guard [Proc, nil] optional guard — receives context, returns truthy/falsy
      def event(name, from:, to:, guard: nil)
        dest = (to == :__finish__) ? FINISH : to
        @event_transitions << {name: name, from: from, to: dest, guard: guard}
      end

      # Builds and returns a Phronomy::Workflow backed by a WorkflowRunner.
      def build
        nodes = @states.dup
        edges = build_edges
        conditional_edges = build_conditional_edges
        wait_states = build_wait_states

        runner = Phronomy::WorkflowRunner.new(
          state_class: @context_class,
          nodes: nodes,
          edges: edges,
          conditional_edges: conditional_edges,
          entry_point: @initial || nodes.keys.first,
          wait_states: wait_states
        )

        Workflow.new(runner)
      end

      private

      # Converts @after_transitions and non-guarded @event_transitions into
      # the edges hash expected by WorkflowRunner: { from => [{to:, condition:}] }
      #
      # Event transitions whose from-node also has guarded transitions are omitted
      # here; they are handled inside build_conditional_edges as a fallback.
      def build_edges
        edges = {}

        # After-transitions (unconditional edges fired after action completes)
        @after_transitions.each do |t|
          edges[t[:from]] ||= []
          edges[t[:from]] << {to: t[:to], condition: nil}
        end

        # Collect from-nodes that already have at least one guarded event
        from_with_guards = @event_transitions.select { |t| t[:guard] }.map { |t| t[:from] }.to_set

        # Unconditional event transitions are plain edges ONLY when no guarded
        # event exists from the same source node.  When guards are present the
        # unguarded transition acts as a fallback and is wired inside
        # build_conditional_edges instead.
        @event_transitions.reject { |t| t[:guard] }.each do |t|
          next if from_with_guards.include?(t[:from])
          edges[t[:from]] ||= []
          edges[t[:from]] << {to: t[:to], condition: nil}
        end

        edges
      end

      # Converts guarded event transitions into the conditional_edges hash:
      # { from => { condition: Proc, mapping: nil } }
      #
      # Multiple guarded transitions from the same source are combined into a
      # single routing proc.  An unguarded transition from the same source is
      # used as an automatic fallback when all guards fail.
      def build_conditional_edges
        conditional_edges = {}

        guarded = @event_transitions.select { |t| t[:guard] }
        guarded.group_by { |t| t[:from] }.each do |from, transitions|
          # Unguarded fallback for this from-node (may be nil)
          fallback = @event_transitions.find { |t| t[:from] == from && t[:guard].nil? }

          routing = lambda do |state|
            matched = transitions.find { |t| t[:guard].call(state) }
            next matched[:to] if matched
            fallback&.fetch(:to)
          end
          conditional_edges[from] = {condition: routing, mapping: nil}
        end

        conditional_edges
      end

      # Converts wait_state declarations plus event-driven transitions *to*
      # wait states into the wait_states hash:
      # { wait_state_name => { resume_event: Symbol, resume_to: Symbol } }
      #
      # For each wait state, we look for the first event declared as
      # `event :X, from: :wait_state_name, to: :Y` and use that as the
      # resume_event / resume_to pair. If multiple events exist for the same
      # wait state, subsequent ones are registered as additional named events.
      def build_wait_states
        wait_states = {}

        @wait_state_names.each do |ws|
          # Find events that originate from this wait state
          outgoing = @event_transitions.select { |t| t[:from] == ws }
          primary = outgoing.first

          wait_states[ws] = {
            resume_event: primary&.fetch(:name),
            resume_to: primary&.fetch(:to)
          }

          # Additional events from the same wait state are also registered so
          # that send_event(:other_event) works for branching wait states.
          outgoing.drop(1).each do |t|
            wait_states[:"#{ws}__#{t[:name]}"] = {
              resume_event: t[:name],
              resume_to: t[:to]
            }
          end
        end

        wait_states
      end
    end
  end
end
