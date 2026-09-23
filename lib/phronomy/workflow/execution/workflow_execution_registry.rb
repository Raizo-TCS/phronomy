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

    def initialize(event_loop:)
      super
      @workflow_admissions = {}
    end

    def post(command, admission: false, completion: nil)
      post_message(command, admission: admission, completion: completion)
    end

    def deliver(command)
      assert_event_loop_thread!
      command.runner.deliver_on_event_loop(command)
    end

    def idle?
      !workflow_admission_transition_in_progress_locked?
    end

    def session_retired(fsm_session_id, reason:)
      assert_event_loop_thread!
      mark_workflow_recovery_required_for_session(fsm_session_id) if reason == :recovery_required
    end

    def shutdown(error:)
      synchronize { @workflow_admissions.clear }
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
      synchronize do
        current = @workflow_admissions[key]
        next false unless current&.owner_token&.equal?(owner_token)

        @workflow_admissions.delete(key)
        true
      end
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
      @event_loop.__route_execution_event(self) do
        admission = @workflow_admissions[workflow_instance_id.to_s]
        next unless admission&.state == :executing && admission.fsm_session_id

        Phronomy::Event.new(
          type: event.to_sym, target_id: admission.fsm_session_id, payload: payload
        )
      end
    end

    private

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
