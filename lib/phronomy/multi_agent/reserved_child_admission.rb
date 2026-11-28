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
            when "subagent" then validate_subagent!(records, admission, scope)
            when "handoff" then validate_handoff!(records, admission, scope)
            end
            admission.accept_in(scope)
          end
        end
        nil
      end

      private

      # Private opt-in: retry repeats Agent writes under current reservation
      # guards. It never invokes the original thread-affine admission callback.
      def initial_recovery_authority(admission, scope:, persistence:)
        InitialAuthority.new(self, admission, scope, persistence, store: @persistence, owner: @owner)
      end

      class InitialAuthority
        Identity = Data.define(:agent_id, :execution_id, :correlation)
        private_constant :Identity

        def initialize(participant, admission, scope, persistence, store:, owner:)
          @participant = participant
          @store, @owner = store, owner
          @identity = persistence.execution_evidence_identity
          @admission = Identity.new(agent_id: admission.agent_id, execution_id: admission.execution_id,
            correlation: admission.correlation)
          guard(scope: scope, persistence: persistence)
          @handoff_footprint = handoff_footprint(scope) if @owner.fetch("kind") == "handoff"
          assert_current!(scope: scope, persistence: persistence)
          freeze
        end

        def guard(scope:, persistence:)
          assert_store!(persistence)
          @store.participate(scope) do |records|
            case @owner.fetch("kind")
            when "team" then records.guard_team!(@owner.fetch("team_id"))
            when "subagent"
              persistence.guard_agents(scope, agent_ids: [@owner.fetch("parent_agent_id"), @admission.agent_id])
            when "handoff"
              routing = records.handoff_states.load_locked(@owner.fetch("main_agent_id"))
              ids = [@owner.fetch("main_agent_id"), @admission.agent_id,
                (routing.metadata["source_agent_id"] if routing && routing.phase != "stable")].compact
              persistence.guard_agents(scope, agent_ids: ids)
            end
          end
          nil
        end

        def assert_current!(scope:, persistence:)
          assert_store!(persistence)
          unless @admission.correlation == @owner
            raise Phronomy::Persistence::StateConflictError, "Initial reservation identity changed"
          end
          @store.participate(scope) do |records|
            case @owner.fetch("kind")
            when "team" then @participant.send(:validate_team!, records, @admission)
            when "subagent" then @participant.send(:validate_subagent!, records, @admission, scope)
            when "handoff"
              @participant.send(:validate_handoff!, records, @admission, scope)
              unless handoff_footprint(scope) == @handoff_footprint
                raise Phronomy::Persistence::StateConflictError, "Initial Handoff routing or retention changed"
              end
            end
          end
          nil
        end

        # Terminal cleanup is not a fresh dispatch grant. The Agent proof checks
        # the exact root and execution; a cancelled parent may still finish it.
        def assert_cleanup!(scope:, persistence:)
          assert_store!(persistence)
        end

        private

        def assert_store!(persistence)
          unless persistence.equal?(@store.agent_store) &&
              persistence.execution_evidence_identity.equal?(@identity)
            raise Phronomy::Persistence::StateConflictError, "Initial reservation belongs to another Store"
          end
        end

        def handoff_footprint(scope)
          @store.participate(scope) do |records|
            routing = records.handoff_states.load(@owner.fetch("main_agent_id"))
            ids = [@owner.fetch("main_agent_id"), @admission.agent_id,
              (routing.metadata["source_agent_id"] if routing && routing.phase != "stable")].compact.uniq.sort
            Phronomy::Values::Immutable.copy([routing&.to_h, ids.map { |id|
              @store.agent_store.retained_references(agent_id: id, scope: scope).map(&:to_h)
                .sort_by { |hold| Phronomy::CanonicalJSON.dump(hold) }
            }])
          end
        end
      end
      private_constant :InitialAuthority

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

      def validate_subagent!(records, admission, scope)
        @persistence.agent_store.guard_agents(scope, agent_ids: [@owner.fetch("parent_agent_id"), admission.agent_id])
        parent = @persistence.agent_store.observe_execution(agent_id: @owner.fetch("parent_agent_id"),
          execution_id: @owner.fetch("parent_execution_id"), scope: scope)
        unless parent.continuable?
          raise Phronomy::CancellationError, "Parent run is no longer dispatchable"
        end
        extension = @persistence.agent_store.execution_extension(agent_id: parent.agent_id, execution_id: parent.execution_id,
          binding_key: DurableSubagentCoordinator::BINDING_KEY, scope: scope)
        snapshot = records.contents.fetch_json(extension.state_ref)
        raise Phronomy::CancellationError, "Parent reservation was cancelled" if snapshot["cancel_requested"]
        slot = snapshot.fetch("children").find { |entry| entry.fetch("slot") == @owner.fetch("slot") }
        unless slot && slot.fetch("agent_id") == admission.agent_id && slot.fetch("execution_id") == admission.execution_id
          raise Phronomy::Persistence::StateConflictError, "Parent reserved child identity mismatch"
        end
      end

      def validate_handoff!(records, admission, scope)
        routing = records.handoff_states.load_locked(@owner.fetch("main_agent_id"))
        unless routing && routing.active_agent_id == admission.agent_id
          raise Phronomy::Persistence::StateConflictError, "Handoff responsibility changed before admission"
        end
        if Array(routing.metadata["cancelled_execution_ids"]).include?(admission.execution_id)
          raise Phronomy::CancellationError, "Handoff reservation was cancelled"
        end
        ids = [@owner.fetch("main_agent_id"), admission.agent_id]
        ids << routing.metadata["source_agent_id"] unless routing.phase == "stable"
        @persistence.agent_store.guard_agents(scope, agent_ids: ids.compact)
        if routing.phase != "stable" && routing.pending_target_execution_id != admission.execution_id
          raise Phronomy::Persistence::StateConflictError, "Handoff reserved Target identity mismatch"
        end
      end
    end
  end
end
