# frozen_string_literal: true

module Phronomy
  # I07 translates C02 task-state decisions to generic FSM progression. Engine
  # does not learn TaskResult ownership, cancellation or stale-result policy.
  # @api private
  class WorkflowTaskSession < FSMSession
    def initialize(task_execution:, **options)
      super(**options)
      @task_execution = task_execution
      @task_execution.bind(self)
    end

    def start
      @task_execution.activate
      super unless @done
    rescue => error
      finish_with_error(error)
    end

    def apply_task_context(context)
      return unless @terminal_lifecycle_state == :running

      @ctx = @context = context
      apply_context_metadata!
      @tracker.context = context
      advance_or_halt
    rescue => error
      finish_with_error(error)
    end

    def fail_task_execution(error)
      finish_with_error(error) if @terminal_lifecycle_state == :running
    end

    def handle(event)
      return if event.type == :state_completed && !@task_execution.permits_completion?(event.payload)

      super
    end

    private

    def post_session_event(type, payload = nil)
      payload = @task_execution.completion_key if type == :state_completed
      super
    end

    def advance_or_halt
      if @task_execution.enter(@current_state, @ctx)
        notify_stable_state!
      else
        super
      end
    end

    def build_tracker(from_state)
      super.tap { |tracker| tracker.workflow_task_execution = @task_execution }
    end

    def request_terminal!(...)
      @task_execution.close
      super
    end

    def finish_with_error(error)
      @task_execution.close
      super
    end

    def retire_without_result!(error)
      @task_execution.retire(error)
      super
    end
  end
end
