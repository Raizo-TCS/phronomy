# frozen_string_literal: true

module Phronomy
  # Workflow's synchronous callback rules, independent of FSM representation.
  # Guards and transition actions may receive the triggering application event;
  # actions may initiate async work but must not return a TaskResult.
  # @api private
  module WorkflowActionRules
    module_function

    def allowed?(guard, context, event)
      guard.nil? || call_with_optional_event(guard, context, event)
    end

    def transition(callable, context, event, metadata:)
      return context if callable.nil?

      result = call_with_optional_event(callable, context, event)
      if result.is_a?(Phronomy::TaskResult)
        raise Phronomy::InvalidAsyncTransitionActionError,
          "Transition action " \
            "#{metadata[:from].inspect} --#{metadata[:event].inspect}--> " \
            "#{metadata[:to].inspect} returned Phronomy::TaskResult. " \
            "Start the asynchronous operation, register its callback/listener, " \
            "and return the WorkflowContext or nil."
      end
      workflow_context_result?(result) ? result : context
    end

    def entry(callable, context, state_name)
      result = callable.call(context)
      if result.is_a?(Phronomy::TaskResult)
        raise Phronomy::InvalidAsyncEntryActionError,
          "Entry action for state #{state_name.inspect} returned Phronomy::TaskResult. " \
            "Start the asynchronous operation, register its callback/listener, " \
            "and return the WorkflowContext or nil."
      end
      result
    end

    def apply_entry(callable, context, state_name)
      result = entry(callable, context, state_name)
      workflow_context_result?(result) ? result : context
    end

    def exit(callable, context, state_name)
      result = callable.call(context)
      if result.is_a?(Phronomy::TaskResult)
        raise Phronomy::InvalidAsyncEntryActionError,
          "Exit action for state #{state_name.inspect} returned Phronomy::TaskResult. " \
            "Exit actions are synchronous Run-to-Completion callbacks."
      end
      nil
    end

    def call_with_optional_event(callable, context, event)
      parameters = callable.respond_to?(:parameters) ? callable.parameters : callable.method(:call).parameters
      (parameters.length >= 2) ? callable.call(context, event) : callable.call(context)
    end
    private_class_method :call_with_optional_event

    def workflow_context_result?(result)
      result.respond_to?(:set_graph_metadata)
    end
    private_class_method :workflow_context_result?
  end
end
