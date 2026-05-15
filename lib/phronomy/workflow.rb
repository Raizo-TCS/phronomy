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
    # @param state_store [Object, nil] optional state store override (passed to WorkflowRunner)
    # @yield block evaluated in DSL context
    # @return [Phronomy::Workflow] compiled and ready-to-run workflow instance
    def self.define(context_class, state_store: nil, &block)
      builder = Builder.new(context_class, state_store: state_store)
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

      def initialize(context_class, state_store: nil)
        @context_class = context_class
        @state_store = state_store
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

        # After-transitions: { from => to }
        # Unconditional transitions that fire automatically after an action state completes.
        after_transitions = @after_transitions.each_with_object({}) do |t, h|
          h[t[:from]] = t[:to]
        end

        # Route transitions: { from => {event_name:, entries: [{guard:, to:}, ...]} }
        # Events declared from action states (not wait states) fire automatically
        # after the action completes. The event name is used to register the
        # state_machines event and may be any symbol (e.g. :route, :route_review).
        # Declaration order is preserved so guarded entries appear before fallbacks.
        route_transitions = {}

        # External events: { event_name => [{from:, to:, guard:}, ...] }
        # Events declared from wait states, triggered by human input (e.g. :approve).
        external_events = {}

        @event_transitions.each do |t|
          if @wait_state_names.include?(t[:from])
            # Source is a wait state → external event
            external_events[t[:name]] ||= []
            external_events[t[:name]] << {from: t[:from], to: t[:to], guard: t[:guard]}
          else
            # Source is an action state → routing event (auto-fires after action)
            # The event name is taken from the first declaration for each from-state.
            route_transitions[t[:from]] ||= {event_name: t[:name], entries: []}
            route_transitions[t[:from]][:entries] << {guard: t[:guard], to: t[:to]}
          end
        end

        runner = Phronomy::WorkflowRunner.new(
          state_class: @context_class,
          nodes: nodes,
          after_transitions: after_transitions,
          route_transitions: route_transitions,
          external_events: external_events,
          entry_point: @initial || nodes.keys.first,
          wait_state_names: @wait_state_names,
          state_store: @state_store
        )

        Workflow.new(runner)
      end
    end
  end
end
