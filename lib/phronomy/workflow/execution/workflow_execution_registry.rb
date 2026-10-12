# frozen_string_literal: true

module Phronomy
  # Workflow-owned segment admission and routing, mutated only on EventLoop.
  # @api private
  class WorkflowExecutionRegistry < Phronomy::ExecutionReceiver
    # Workflow-owned process-local Workflow execution-segment admission. The
    # owner token is a Runtime coordination capability, not a domain identity or
    # routing identity. fsm_session_id is bound only after durable load/hydration
    # completes and a concrete FSMSession has been constructed.
    WorkflowAdmission = Data.define(
      :workflow_instance_id, :owner_token, :fsm_session_id, :state
    )
    private_constant :WorkflowAdmission
    StopTaskExecutions = Data.define(:error)
    private_constant :StopTaskExecutions

    def initialize(channel:)
      super
      @workflow_admissions = {}
      @task_executions = {}
      @draining = false
    end

    def post(command, admission: false, completion: nil)
      post_message(command, admission: admission, completion: completion)
    end

    def deliver(command)
      assert_event_loop_thread!
      case command
      when WorkflowTaskReception::Notification
        task_execution_for(command.reception)&.receive(command)
      when WorkflowTaskReception::DeliveryFailure
        task_execution_for(command.reception)&.delivery_failed(command.reception, command.error)
      when WorkflowTaskReception::Cancellation
        task_execution_for(command.reception)&.receive_cancellation(command.reception)
      when StopTaskExecutions
        synchronize { @task_executions.values.dup }.each { |execution| execution.stop(command.error) }
      else
        command.runner.deliver_on_event_loop(command)
      end
    end

    def idle?
      !workflow_admission_transition_in_progress_locked?
    end

    def session_retired(fsm_session_id, reason:)
      assert_event_loop_thread!
      mark_workflow_recovery_required_for_session(fsm_session_id) if reason == :recovery_required
    end

    def shutdown(error:)
      executions = synchronize do
        @workflow_admissions.clear
        values = @task_executions.values
        @task_executions.clear
        values
      end
      failure = error || Phronomy::RuntimeShutdownError.new("Runtime stopped Workflow task execution")
      executions.each { |execution| execution.retire(failure) }
    end

    # Called under Runtime's lifecycle lock. Only queue owner-side decisions;
    # do not call application code or acquire Runtime again from here.
    def begin_draining
      first = synchronize do
        next false if @draining
        @draining = true
      end
      post(StopTaskExecutions.new(error: Phronomy::RuntimeShutdownError.new("Runtime stopped Workflow task execution"))) if first
    end

    def wait_until_idle(_deadline)
      # EventLoop's existing admission/delivery accounting owns the drain wait.
      true
    end

    def draining?
      synchronize { @draining }
    end

    def bind_task_execution(execution)
      assert_event_loop_thread!
      synchronize { @task_executions[execution.owner_token] = execution }
    end

    def task_delivery_failed(reception, error)
      return unless reception.active? && task_execution_for(reception)

      failure = WorkflowTaskReception::DeliveryFailure.new(reception: reception, error: error)
      return if post(failure)

      fail_task_observer(reception, error)
    rescue => delivery_error
      fail_task_observer(reception, error || delivery_error)
    end

    # Reserves one logical Workflow execution segment before durable load or
    # hydration. The owner token is independent from any later FSMSession id.
    # @api private
    def admit_workflow(workflow_instance_id, owner_token:)
      assert_event_loop_thread!
      key = workflow_instance_id.to_s
      raise ArgumentError, "workflow_instance_id must not be empty" if key.empty?
      raise ArgumentError, "owner_token is required" unless owner_token

      admit do
        if @workflow_admissions.key?(key)
          raise Phronomy::Error,
            "Workflow instance #{key.inspect} already has a live execution segment"
        end
        @workflow_admissions[key] = WorkflowAdmission.new(
          workflow_instance_id: key.freeze,
          owner_token: owner_token,
          fsm_session_id: nil,
          state: :admitting
        )
      end
      true
    end

    # Binds the concrete routing identity after admission and durable hydration.
    # @api private
    def bind_workflow_session(workflow_instance_id, owner_token:, fsm_session_id:)
      assert_event_loop_thread!
      key = workflow_instance_id.to_s
      fsm_key = fsm_session_id.to_s
      raise ArgumentError, "fsm_session_id must not be empty" if fsm_key.empty?

      synchronize do
        current = @workflow_admissions.fetch(key) do
          raise Phronomy::Error, "Workflow instance #{key.inspect} has no Runtime admission"
        end
        unless current.owner_token.equal?(owner_token) && current.fsm_session_id.nil?
          raise Phronomy::Error, "stale Workflow admission bind for #{key.inspect}"
        end
        @workflow_admissions[key] = WorkflowAdmission.new(
          workflow_instance_id: current.workflow_instance_id,
          owner_token: current.owner_token,
          fsm_session_id: fsm_key.freeze,
          state: :executing
        )
      end
      true
    end

    # @api private
    def mark_workflow_admission(workflow_instance_id, owner_token:, state:)
      assert_event_loop_thread!
      key = workflow_instance_id.to_s
      next_state = state.to_sym
      unless %i[executing persisting_terminal recovery_required].include?(next_state)
        raise ArgumentError, "unsupported Workflow admission state: #{next_state.inspect}"
      end

      synchronize do
        current = @workflow_admissions.fetch(key) do
          raise Phronomy::Error, "Workflow instance #{key.inspect} has no Runtime admission"
        end
        unless current.owner_token.equal?(owner_token)
          raise Phronomy::Error, "stale Workflow admission update for #{key.inspect}"
        end
        @workflow_admissions[key] = WorkflowAdmission.new(
          workflow_instance_id: current.workflow_instance_id,
          owner_token: current.owner_token,
          fsm_session_id: current.fsm_session_id,
          state: next_state
        )
      end
      true
    end

    # Owner-aware release. A competing or stale attempt cannot release the
    # current Workflow execution segment.
    # @api private
    def release_workflow(workflow_instance_id, owner_token:)
      assert_event_loop_thread!
      key = workflow_instance_id.to_s
      execution = nil
      released = synchronize do
        current = @workflow_admissions[key]
        next false unless current&.owner_token&.equal?(owner_token)

        @workflow_admissions.delete(key)
        execution = @task_executions.delete(owner_token)
        true
      end
      execution&.close
      released
    end

    # Read-only diagnostics used by internal tests and routing assertions.
    def workflow_admission_owner(workflow_instance_id)
      synchronize do
        @workflow_admissions[workflow_instance_id.to_s]&.owner_token
      end
    end

    def workflow_admission_fsm_session_id(workflow_instance_id)
      synchronize do
        @workflow_admissions[workflow_instance_id.to_s]&.fsm_session_id
      end
    end

    def workflow_admission_state(workflow_instance_id)
      synchronize do
        @workflow_admissions[workflow_instance_id.to_s]&.state
      end
    end

    def post_to_workflow(workflow_instance_id:, event:, payload: nil)
      route_event(type: event.to_sym, payload: payload) do
        admission = @workflow_admissions[workflow_instance_id.to_s]
        next unless admission&.state == :executing && admission.fsm_session_id

        admission.fsm_session_id
      end
    end

    private

    def task_execution_for(reception)
      synchronize { @task_executions[reception.owner_token] }
    end

    def fail_task_observer(reception, error)
      # A fully unavailable owner cannot safely release admission or claim a
      # durable terminal result. Settle observation only; shutdown owns cleanup.
      task_execution_for(reception)&.result_task&.fail(error) if reception.active?
    end

    def mark_workflow_recovery_required_for_session(fsm_session_id)
      synchronize do
        key, admission = @workflow_admissions.find do |_workflow_instance_id, candidate|
          candidate.fsm_session_id == fsm_session_id.to_s
        end
        return false unless admission

        @workflow_admissions[key] = WorkflowAdmission.new(
          workflow_instance_id: admission.workflow_instance_id,
          owner_token: admission.owner_token,
          fsm_session_id: nil,
          state: :recovery_required
        )
      end
      true
    end

    def workflow_admission_transition_in_progress_locked?
      @workflow_admissions.values.any? do |admission|
        %i[admitting executing persisting_terminal].include?(admission.state)
      end
    end
  end
end
