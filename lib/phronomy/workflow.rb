# frozen_string_literal: true

require_relative "workflow_runner"
require_relative "runnable"

module Phronomy
  # StateChart-style workflow definition DSL.
  #
  # Defines agent workflows in terms of *states* and *events* backed by
  # Phronomy::WorkflowRunner. This is the primary high-level API
  # for workflow-based execution in phronomy.
  #
  # == Basic usage
  #
  #   app = Phronomy::Workflow.define(MyContext) do
  #     initial :fetch
  #
  #     state :fetch
  #     state :process
  #
  #     entry :fetch,   FETCH_NODE
  #     entry :process, PROCESS_NODE
  #
  #     transition from: :fetch,   to: :process
  #     transition from: :process, to: :__finish__
  #   end
  #
  #   result = app.invoke({ url: "https://example.com" })
  #
  # == Wait states
  #
  #   app = Phronomy::Workflow.define(MyContext) do
  #     initial :propose
  #
  #     state :propose
  #     wait_state :awaiting_approval
  #     state :execute
  #
  #     entry :propose, PROPOSE_NODE
  #     entry :execute, EXECUTE_NODE
  #
  #     transition from: :propose, to: :awaiting_approval
  #     transition from: :execute, to: :__finish__
  #
  #     transition from: :awaiting_approval, on: :approve, to: :execute
  #     transition from: :awaiting_approval, on: :reject,  to: :propose
  #   end
  #
  #   halted = app.invoke({ ... })
  #   final  = app.send_event(state: halted, event: :approve)
  #
  # == Conditional transitions
  #
  #   transition from: :decide, guard: ->(s) { s.score > 5 }, to: :high
  #   transition from: :decide, to: :low   # fallback (no guard)
  #
  class Workflow
    include Phronomy::Runnable

    # Defines a new Workflow.
    # @param context_class [Class] class that includes Phronomy::WorkflowContext
    # @yield block evaluated in DSL context
    # @return [Phronomy::Workflow] compiled and ready-to-run workflow instance
    # @raise [ArgumentError] if no states are declared (empty workflow)
    # @raise [ArgumentError] if any transition references an undeclared +to:+ or +from:+ state
    # @api public
    def self.define(context_class, &block)
      builder = Builder.new(context_class)
      builder.instance_eval(&block)
      builder.build
    end

    # @param runner [Phronomy::WorkflowRunner]
    # @api public
    def initialize(runner)
      @runner = runner
    end

    # Executes the workflow from the initial state.
    # @param input [Hash] initial context field values
    # @param config [Hash] { thread_id:, recursion_limit:, user_id:, session_id: }
    # @return [Object] final context
    # @api public
    def invoke(input, config: {})
      @runner.invoke(input, config: config)
    end

    # Resumes a halted workflow. Generic resume that works for all halt types.
    # @param state [Object] halted context
    # @param input [Hash, nil] optional field updates to merge before resuming
    # @return [Object] final context
    # @api public
    def resume(state:, input: nil)
      @runner.resume(state: state, input: input)
    end

    # Fires a named event to advance a halted workflow.
    # @param state [Object] halted context
    # @param event [Symbol] event name (e.g. :approve, :reject, :resume)
    # @param input [Hash, nil] optional field updates to merge before resuming
    # @return [Object] final context
    # @api public
    def send_event(state:, event:, input: nil)
      @runner.send_event(state: state, event: event, input: input)
    end

    # Streaming execution. Yields { state: Symbol, context: Object } after each state action.
    # @param input [Hash]
    # @param config [Hash]
    # @yield [Hash]
    # @return [Object] final context
    # @api public
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
        # Ordered list of declared state names (action states only, not wait states).
        @declared_states = []
        # { state_name => [callable, ...] } — entry actions registered via entry()
        @entry_actions = {}
        # { state_name => [callable, ...] } — exit actions registered via exit()
        @exit_actions = {}
        # Array of { from:, to:, guard:, on: } — all transitions in declaration order
        @transitions = []
        # Set of wait state names
        @wait_state_names = []
      end

      # Declares the initial (entry) state.
      # @param state_name [Symbol]
      # rubocop:disable Style/TrivialAccessors
      # @api public
      def initial(state_name)
        @initial = state_name
      end
      # rubocop:enable Style/TrivialAccessors

      # Declares an action state.
      # @param name   [Symbol]   state name
      # @param action [#call, nil] optional entry action shorthand.
      #   +state :generate, action: MY_PROC+ is equivalent to
      #   +state :generate; entry :generate, MY_PROC+.
      # @api public
      def state(name, action: nil)
        @declared_states << name
        entry(name, action) if action
      end

      # Declares an entry action for a state.
      # The callable is invoked when the workflow enters +name+.
      # It receives the current context. Two styles are supported:
      #   - Mutation-in-place: mutate context fields directly (+s.field = value+);
      #     the return value is ignored.
      #   - Immutable update: return a new context via +s.merge(field: value)+;
      #     the returned context replaces the current one.
      # Multiple calls for the same state are allowed; callables fire in declaration order.
      # @param name [Symbol] state name
      # @param callable [#call] receives context; may return a new WorkflowContext
      # @api public
      def entry(name, callable)
        (@entry_actions[name] ||= []) << callable
      end

      # Declares an exit action for a state.
      # The callable is invoked when the workflow leaves +name+.
      # It receives the current context and should mutate it in place.
      # Return value is ignored.
      # Multiple calls for the same state are allowed; callables fire in declaration order.
      # @param name [Symbol] state name
      # @param callable [#call] receives context, mutates it in place
      # @api public
      def exit(name, callable)
        (@exit_actions[name] ||= []) << callable
      end

      # Declares a wait state that automatically halts execution when reached.
      # No entry action is registered; the workflow pauses here until an event resumes it.
      # @param name [Symbol] wait state name (conventionally :awaiting_something)
      # @api public
      def wait_state(name)
        @wait_state_names << name
      end

      # Declares a transition between states.
      # Auto-fire transitions (no +on:+) fire automatically when an action state's
      # action completes. External transitions (+on: :event_name+) are triggered
      # manually via +send_event+.
      # When +guard:+ is provided the transition is taken only if the guard returns
      # truthy for the current context. Multiple transitions from the same source are
      # evaluated in declaration order; the first passing guard wins.
      # @param from [Symbol] source state
      # @param to [Symbol] destination state or :__finish__
      # @param guard [Proc, nil] optional guard — receives context, returns truthy/falsy
      # @param on [Symbol, nil] named event for manual triggers (e.g. :approve)
      # @api public
      def transition(from:, to:, guard: nil, on: nil)
        dest = (to == :__finish__) ? FINISH : to
        @transitions << {from: from, to: dest, guard: guard, on: on}
      end

      private

      # Performs build-time structural validation of the workflow graph.
      # Raises ArgumentError for hard errors; warns for unreachable states.
      def validate_graph!
        all_states = (@declared_states + @wait_state_names).uniq
        entry_point = @initial || @declared_states.first

        if entry_point.nil?
          raise ArgumentError, "Workflow has no states declared — call state(...) or wait_state(...) at least once"
        end

        # Collect all reachable state names from transitions (excluding :__finish__ sentinel).
        referenced_targets = @transitions.map { |t| t[:to] }.reject { |t| t == FINISH }
        undefined = referenced_targets - all_states
        unless undefined.empty?
          raise ArgumentError,
            "Workflow transition(s) reference undefined state(s): #{undefined.sort.inspect}. " \
            "Declare each with state(...) or wait_state(...)."
        end

        # Check that all from: states in transitions are declared.
        referenced_sources = @transitions.map { |t| t[:from] }
        undefined_sources = referenced_sources - all_states
        unless undefined_sources.empty?
          raise ArgumentError,
            "Workflow transition(s) originate from undefined state(s): #{undefined_sources.sort.inspect}. " \
            "Declare each with state(...) or wait_state(...)."
        end

        # Reachability check: warn about declared states that cannot be reached
        # from the initial state (transition target not referenced by any transition).
        reachable = Set.new([entry_point])
        queue = [entry_point]
        until queue.empty?
          current = queue.shift
          @transitions.each do |t|
            next if t[:from] != current
            next if t[:to] == FINISH
            unless reachable.include?(t[:to])
              reachable.add(t[:to])
              queue << t[:to]
            end
          end
        end

        unreachable = all_states - reachable.to_a
        unless unreachable.empty?
          msg = "[Phronomy] Workflow has unreachable state(s): #{unreachable.sort.inspect}. " \
                "These states can never be entered from the initial state '#{entry_point}'."
          if Phronomy.configuration.logger
            Phronomy.configuration.logger.warn(msg)
          else
            warn msg
          end
        end
      end

      public

      # Builds and returns a Phronomy::Workflow backed by a WorkflowRunner.
      # Performs build-time validation of the graph structure:
      #   - raises ArgumentError when no initial state is declared and no states have been defined
      #   - raises ArgumentError when a transition references an undeclared target state
      #   - warns when declared states are unreachable from the initial state
      # @raise [ArgumentError] on structural errors
      # @api public
      def build
        entry_actions = @entry_actions.dup
        exit_actions = @exit_actions.dup

        validate_graph!

        # Auto-fire transitions (no :on): fire automatically when action completes.
        # External events (with :on): triggered manually via send_event.
        auto_transitions = []
        external_events = {}

        @transitions.each do |t|
          if t[:on]
            external_events[t[:on]] ||= []
            external_events[t[:on]] << {from: t[:from], to: t[:to], guard: t[:guard]}
          else
            auto_transitions << {from: t[:from], to: t[:to], guard: t[:guard]}
          end
        end

        runner = Phronomy::WorkflowRunner.new(
          state_class: @context_class,
          entry_actions: entry_actions,
          exit_actions: exit_actions,
          declared_states: @declared_states.dup,
          auto_transitions: auto_transitions,
          external_events: external_events,
          entry_point: @initial || @declared_states.first,
          wait_state_names: @wait_state_names
        )

        Workflow.new(runner)
      end
    end
  end
end
