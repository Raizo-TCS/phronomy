# frozen_string_literal: true

require_relative "workflow_runner"
require_relative "runnable"

module Phronomy
  # StateChart-style Workflow definition DSL.
  class Workflow
    include Phronomy::Runnable

    def self.define(context_class, state_store: nil, &block)
      builder = Builder.new(context_class, state_store: state_store)
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

    # Sends an event to an active Workflow session without blocking.
    #
    # This method is safe to call from an Agent/Tool listener running on the
    # EventLoop thread because it only enqueues a later dispatch.
    #
    # @return [Boolean] true when admitted; false when the session is not live
    #   or Runtime shutdown has begun
    def signal(thread_id:, event:, payload: nil)
      @runner.signal(
        thread_id: thread_id,
        event: event,
        payload: payload
      )
    end

    private

    def _apply_invocation_context(config, invocation_context)
      effective = config.merge(invocation_context: invocation_context)
      if effective[:thread_id].nil? && invocation_context.thread_id
        effective = effective.merge(thread_id: invocation_context.thread_id)
      end
      if effective[:cancellation_token].nil?
        token = invocation_context.effective_timeout_token
        effective = effective.merge(cancellation_token: token) if token
      end
      effective
    end

    public

    class Builder
      FINISH = Phronomy::WorkflowRunner::FINISH

      def initialize(context_class, state_store: nil)
        @context_class = context_class
        @state_store = state_store
        @initial = nil
        @declared_states = []
        @entry_actions = {}
        @exit_actions = {}
        @transitions = []
        @wait_state_names = []
      end

      def initial(state_name) # rubocop:disable Style/TrivialAccessors
        @initial = state_name
      end

      # Declares a Workflow state.
      #
      # Entry actions are synchronous Run-to-Completion callbacks. To start
      # asynchronous work, register its listener/callback inside the action and
      # return the context or nil. Returning Phronomy::Task is an error.
      def state(name, action: nil)
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
        @wait_state_names << name
      end

      # Guards may accept either (context) or (context, event).
      def transition(from:, to:, guard: nil, on: nil)
        destination = (to == :__finish__) ? FINISH : to
        @transitions << {
          from: from,
          to: destination,
          guard: guard,
          on: on
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
              guard: transition[:guard]
            }
          else
            auto_transitions << {
              from: transition[:from],
              to: transition[:to],
              guard: transition[:guard]
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
          state_store: @state_store
        )
        Workflow.new(runner)
      end

      private

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
          .reject { |target| target == FINISH } - all_states
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
            next if transition[:to] == FINISH
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
        logger = Phronomy.configuration.logger
        logger ? logger.warn(message) : Kernel.warn(message)
      end
    end
  end
end
