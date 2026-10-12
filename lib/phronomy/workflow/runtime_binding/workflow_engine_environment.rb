# frozen_string_literal: true

module Phronomy
  # Connects one compiled Workflow to its owning Runtime. Construction and
  # transition compilation do not start workers or register execution state.
  # @api private
  class WorkflowEngineEnvironment < WorkflowExecutionEnvironment
    def initialize(runtime: Phronomy::Runtime.instance)
      @runtime = runtime
    end

    def registry
      receiver = WorkflowExecutionRegistry.for(@runtime.event_loop)
      @runtime.__shutdown_participant(key: WorkflowExecutionRegistry) ||
        @runtime.__register_shutdown_participant(key: WorkflowExecutionRegistry, participant: receiver)
      receiver
    end

    def existing_registry = WorkflowExecutionRegistry.existing_for(@runtime)
    def executing? = @runtime.event_loop.current?

    def submit(**options, &operation)
      Phronomy::Execution.submit(runtime: @runtime, **options, &operation)
    end

    def compile_transitions(**definition)
      WorkflowPhaseMachineBuilder.new(**definition).build
    end

    def build_session(entry_actions:, persist: nil, task_execution: nil, **options)
      # Preserve nil/scalar results: initial entry must not re-adopt metadata
      # unless the application actually returns a context.
      initial_actions = entry_actions.to_h do |state_name, callbacks|
        [state_name, callbacks.map { |callback| ->(context) { WorkflowActionRules.entry(callback, context, state_name) } }]
      end
      klass = task_execution ? Phronomy::WorkflowTaskSession : Phronomy::FSMSession
      options = options.merge(task_execution: task_execution) if task_execution
      klass.new(**options, entry_actions: initial_actions, event_loop: @runtime.event_loop,
        terminal_policy: persist && WorkflowTerminalPolicy.new(persist: persist))
    end

    def register_session(session, completion:)
      @runtime.event_loop.register(session, completion: completion, receiver: registry)
    end

    def subscribe_cancellation(token, &callback)
      subscriptions = Phronomy::Concurrency::ResultSubscriptions.new
      subscriptions.cancellation(token, &callback)
      remaining = token.remaining_monotonic_seconds
      if remaining && !token.cancelled?
        timer = @runtime.timer_queue
        timer.schedule(seconds: remaining, &callback)
        subscriptions.add { timer.cancel(callback) }
      end
      subscriptions
    rescue
      subscriptions&.close
      raise
    end
  end
end
