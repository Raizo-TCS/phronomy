# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # Owns parent reservation checks and joins the Agent's durable admission.
    # Reconstructed from current coordination wiring, never serialized as a Proc.
    # @api public
    class ReservedChildAdmission
      def initialize(persistence:, owner:)
        @persistence = persistence
        @owner = Phronomy::Values::Immutable.copy(owner)
        raise ArgumentError, "unknown reservation kind" unless %w[team subagent handoff].include?(@owner.fetch("kind"))
        freeze
      end

      # Parent lock, current reservation check and child admission share one scope.
      # No task, runtime owner or live Agent state is published before its commit.
      # @api public
      def admit(admission)
        unless admission.correlation == @owner
          raise Phronomy::Persistence::StateConflictError, "Child admission correlation mismatch"
        end
        @persistence.coordinator.atomic do |scope|
          @persistence.participate(scope) do |records|
            case @owner.fetch("kind")
            when "team" then validate_team!(records, admission)
            when "subagent" then validate_subagent!(records, admission)
            when "handoff" then validate_handoff!(records, admission)
            end
            admission.accept_in(scope)
          end
        end
        nil
      end

      private

      def validate_team!(records, admission)
        records.guard_team!(@owner.fetch("team_id"))
        team = records.team_executions.load(@owner.fetch("team_execution_id"))
        unless team.team_id == @owner.fetch("team_id") && team.active? && !team.metadata["cancel_requested"]
          raise Phronomy::CancellationError, "Team run is no longer dispatchable"
        end
        slot = if @owner.fetch("slot") == "coordinator"
          team.coordinator
        else
          assignment = team.assignments.find { |entry| entry.fetch("task_id") == @owner.fetch("slot") }
          worker = assignment && team.workers.fetch(assignment.fetch("worker"))
          worker&.merge("execution_id" => assignment.fetch("execution_id"))
        end
        unless slot && slot.fetch("execution_id") == admission.execution_id && slot.fetch("agent_id") == admission.agent_id
          raise Phronomy::Persistence::StateConflictError, "Team reserved child identity mismatch"
        end
      end

      def validate_subagent!(records, admission)
        records.guard_agent!(@owner.fetch("parent_agent_id"))
        parent = records.executions.load(@owner.fetch("parent_execution_id"))
        unless parent.agent_id == @owner.fetch("parent_agent_id") && parent.active? && !parent.metadata["coordination_cancel_requested"]
          raise Phronomy::CancellationError, "Parent run is no longer dispatchable"
        end
        snapshot = records.contents.fetch_json(parent.metadata.fetch("multi_agent_coordination_ref"))
        slot = snapshot.fetch("children").find { |entry| entry.fetch("slot") == @owner.fetch("slot") }
        unless slot && slot.fetch("agent_id") == admission.agent_id && slot.fetch("execution_id") == admission.execution_id
          raise Phronomy::Persistence::StateConflictError, "Parent reserved child identity mismatch"
        end
      end

      def validate_handoff!(records, admission)
        routing = records.handoff_states.load_locked(@owner.fetch("main_agent_id"))
        unless routing && routing.active_agent_id == admission.agent_id
          raise Phronomy::Persistence::StateConflictError, "Handoff responsibility changed before admission"
        end
        if Array(routing.metadata["cancelled_execution_ids"]).include?(admission.execution_id)
          raise Phronomy::CancellationError, "Handoff reservation was cancelled"
        end
        if routing.phase != "stable" && routing.pending_target_execution_id != admission.execution_id
          raise Phronomy::Persistence::StateConflictError, "Handoff reserved Target identity mismatch"
        end
      end
    end
  end
end
