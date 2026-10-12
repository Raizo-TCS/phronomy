# frozen_string_literal: true

require_relative "../../execution/concurrency/worker_input_restricted"

require_relative "workflow_runner"
require_relative "../../execution/runnable"

module Phronomy
  # StateChart-style Workflow definition DSL.
  class Workflow
    include Phronomy::Concurrency::WorkerInputRestricted

    include Phronomy::Runnable

    def self.define(context_class, persistence: nil, &block)
      builder = Builder.new(context_class, persistence: persistence)
      builder.instance_eval(&block)
      builder.build
    end

    def initialize(runner)
      @runner = runner
    end

    def invoke(input, config: {}, invocation_context: nil)
      config = _apply_invocation_context(config, invocation_context) if invocation_context
      @runner.invoke(input, config: config)
    end

    def invoke_async(input, config: {}, invocation_context: nil)
      config = _apply_invocation_context(config, invocation_context) if invocation_context
      @runner.invoke_deferred(input, config: config)
    end

    def stream(input, config: {}, invocation_context: nil, &block)
      config = _apply_invocation_context(config, invocation_context) if invocation_context
      @runner.stream(input, config: config, &block)
    end

    def resume(state:, input: nil)
      @runner.resume(state: state, input: input)
    end

    def send_event(state:, event:, input: nil)
      @runner.send_event(state: state, event: event, input: input)
    end

    # Sends an event to an active Workflow execution without blocking.
    #
    # +workflow_instance_id+ is the logical/durable Workflow identity. EventLoop resolves it
    # to the currently owning Runtime-only fsm_session_id. InvocationContext's
    # application session_id is unrelated to this routing.
    #
    # @return [Boolean] true when admitted; false when the Workflow is not live
    #   or Runtime shutdown has begun
    # @api public
    def signal(workflow_instance_id:, event:, payload: nil)
      @runner.signal(
        workflow_instance_id: workflow_instance_id,
        event: event,
        payload: payload
      )
    end

    private

    def _apply_invocation_context(config, invocation_context)
      effective = config.merge(invocation_context: invocation_context)
      if effective[:cancellation_token].nil?
        token = Phronomy::InvocationControls.effective_timeout_token(invocation_context)
        effective = effective.merge(cancellation_token: token) if token
      end
      effective
    end

    public

    class Builder
      def initialize(context_class, persistence: nil)
        @context_class = context_class
        @persistence = persistence
        @initial = nil
        @declared_states = []
        @entry_actions = {}
        @exit_actions = {}
        @transitions = []
        @wait_state_names = []
        @task_states = {}
      end

      def initial(state_name) # rubocop:disable Style/TrivialAccessors
        @initial = state_name
      end

      # Declares a Workflow state.
      #
      # Entry actions are synchronous Run-to-Completion callbacks. To start
      # asynchronous work owned by this state, use task_state. Ordinary actions
      # return the context or nil; returning Phronomy::TaskResult is an error.
      def state(name, action: nil)
        reject_task_state_overlap!(name)
        @declared_states << name
        entry(name, action) if action
      end

      def entry(name, callable)
        (@entry_actions[name] ||= []) << callable
      end

      def exit(name, callable)
        (@exit_actions[name] ||= []) << callable
      end

      def wait_state(name)
        reject_task_state_overlap!(name)
        @wait_state_names << name
      end

      # Starts one asynchronous operation on state entry and advances only
      # after its successful result has been applied on the execution owner.
      # Task completion is correlated to this state entry, not a durable ID.
      # @param name [Symbol] state name
      # @param start [#call] short callback accepting a context snapshot and returning TaskResult
      # @param apply [#call] short callback accepting current context and value; returns context or nil
      # @return [void]
      # @api public
      def task_state(name, start:, apply:)
        unless name.is_a?(Symbol) && start.respond_to?(:call) && apply.respond_to?(:call)
          raise ArgumentError, "task_state requires a Symbol name and callable start/apply"
        end
        if @declared_states.include?(name) || @wait_state_names.include?(name)
          raise ArgumentError, "Workflow state #{name.inspect} is already declared"
        end
        @declared_states << name
        @task_states[name] = {start: start, apply: apply}.freeze
        nil
      end

      # Declares a transition.
      #
      # Guards and actions may accept either (context) or (context, event).
      # Transition actions are synchronous Run-to-Completion callbacks executed
      # after the source exit callbacks and before the target entry callbacks.
      # They may start asynchronous work and register listeners, but returning
      # Phronomy::TaskResult is an error; completion must arrive as a later event.
      def transition(from:, to:, guard: nil, on: nil, action: nil)
        destination = to
        @transitions << {
          from: from,
          to: destination,
          guard: guard,
          on: on,
          action: action
        }
      end

      def build
        validate_graph!

        auto_transitions = []
        external_events = {}
        @transitions.each do |transition|
          if transition[:on]
            event_name = transition[:on].to_sym
            external_events[event_name] ||= []
            external_events[event_name] << {
              from: transition[:from],
              to: transition[:to],
              guard: transition[:guard],
              action: transition[:action],
              event: event_name
            }
          else
            auto_transitions << {
              from: transition[:from],
              to: transition[:to],
              guard: transition[:guard],
              action: transition[:action],
              event: :state_completed
            }
          end
        end

        runner = Phronomy::WorkflowRunner.new(
          state_class: @context_class,
          entry_actions: @entry_actions.dup,
          exit_actions: @exit_actions.dup,
          declared_states: @declared_states.dup,
          auto_transitions: auto_transitions,
          external_events: external_events,
          entry_point: @initial || @declared_states.first,
          wait_state_names: @wait_state_names.dup,
          task_states: @task_states.dup.freeze,
          persistence: @persistence
        )
        Workflow.new(runner)
      end

      private

      def reject_task_state_overlap!(name)
        raise ArgumentError, "Workflow task_state #{name.inspect} is already declared" if @task_states.key?(name)
      end

      def validate_graph!
        all_states = (@declared_states + @wait_state_names).uniq
        entry_point = @initial || @declared_states.first

        unless entry_point
          raise ArgumentError,
            "Workflow has no states declared — call state(...) or " \
            "wait_state(...) at least once"
        end

        undefined_targets = @transitions
          .map { |transition| transition[:to] }
          .reject { |target| target == Completion::FINISH } - all_states
        unless undefined_targets.empty?
          raise ArgumentError,
            "Workflow transition(s) reference undefined state(s): " \
            "#{undefined_targets.sort.inspect}"
        end

        undefined_sources = @transitions
          .map { |transition| transition[:from] } - all_states
        unless undefined_sources.empty?
          raise ArgumentError,
            "Workflow transition(s) originate from undefined state(s): " \
            "#{undefined_sources.sort.inspect}"
        end

        reachable = Set.new([entry_point])
        queue = [entry_point]
        until queue.empty?
          current = queue.shift
          @transitions.each do |transition|
            next unless transition[:from] == current
            next if transition[:to] == Completion::FINISH
            next if reachable.include?(transition[:to])

            reachable.add(transition[:to])
            queue << transition[:to]
          end
        end

        unreachable = all_states - reachable.to_a
        return if unreachable.empty?

        message =
          "[Phronomy] Workflow has unreachable state(s): " \
          "#{unreachable.sort.inspect}. These states can never be entered " \
          "from the initial state #{entry_point.inspect}."
        logger = Phronomy::RuntimeSettings.current.logger
        logger ? logger.warn(message) : Kernel.warn(message)
      end
    end
  end
end
