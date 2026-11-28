# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # Completes one already-terminal pending Target's parent routing obligation.
    # Agent supplies local custody facts; this domain owns routing and retentions.
    # A fresh instance represents each explicit operation and makes at most one
    # synchronous save. Instances are not shared across concurrent callers.
    # @api private
    class HandoffTerminalFinalization
      STATUSES = %i[failed cancelled blocked].freeze
      Snapshot = Data.define(:routing, :source, :target, :proof)
      private_constant :STATUSES, :Snapshot

      def initialize(persistence:, main_agent_id:, agents:)
        @persistence, @main_agent_id, @agents = persistence, main_agent_id, agents
        @agent_store = persistence.agent_store
        @store_identity = @agent_store.execution_evidence_identity
        @owner = {"kind" => "handoff", "main_agent_id" => main_agent_id}.freeze
        @owner_key = "handoff:#{main_agent_id}".freeze
      end

      def call(execution_id:, target:)
        @before = @after = @intended = nil
        return target unless STATUSES.include?(target.status)
        @execution_id, @target = execution_id, target
        snapshot = capture_pending
        return target unless snapshot
        assert_released_custody!(snapshot)
        commit(snapshot)
        target
      rescue HandoffFinalizationError
        raise
      rescue => error
        raise diagnostic(error), cause: error
      end

      private

      def capture_pending
        @persistence.transaction do |records, scope|
          routing = records.handoff_states.load_locked(@main_agent_id)
          next unless routing && routing.phase != "stable" && routing.pending_target_execution_id == @target.execution_id
          unless scope.outermost?
            raise Phronomy::Persistence::TransactionError, "Handoff finalization requires an outermost transaction before observing Agent custody"
          end
          unless routing.phase == "target_pending"
            raise Phronomy::Persistence::StateConflictError, "Handoff finalization requires a pending Target transition"
          end
          capture_in(routing, scope)
        end
      end

      # Never wait for EventLoop while retaining routing or Agent Store guards.
      def assert_released_custody!(snapshot)
        [snapshot.source, snapshot.target].each do |execution|
          agent = @agents[execution.agent_id]
          unless agent && agent.persistence.equal?(@agent_store)
            raise Phronomy::ExecutionRehydrationRequiredError, "Current Handoff graph lacks the exact Source or Target Agent"
          end
          if agent.send(:__execution_custody_pending?, execution.execution_id)
            raise Phronomy::ExecutionRehydrationRequiredError,
              "Agent #{execution.agent_id.inspect} execution #{execution.execution_id.inspect} retains local custody; " \
              "resolve its original recovery before Handoff finalization"
          end
        end
      end

      def commit(snapshot)
        @persistence.transaction do |records, scope|
          routing = records.handoff_states.load_locked(@main_agent_id)
          current = capture_in(routing, scope)
          next if already_finalized?(snapshot, current)
          unless current.proof == snapshot.proof
            raise Phronomy::Persistence::StateConflictError, "Handoff finalization authority changed after custody observation"
          end
          @before = current.proof
          @intended = routing.with(phase: "stable")
          @after = Phronomy::Values::Immutable.copy(@before.merge(routing: @intended.to_h))
          save_routing(records, routing)
        end
      rescue => error
        raise unless @intended
        proof = reconcile_save(error)
        raise diagnostic(error, disposition: proof.disposition, read_error: proof.read_error), cause: error unless proof.disposition == :committed
      end

      def save_routing(records, routing)
        records.handoff_states.save(@main_agent_id, expected_revision: routing.handoff_revision, state: @intended)
      end

      def reconcile_save(error)
        Phronomy::Persistence::SaveOutcome.compare(before: @before, after: @after, original_error: error) do
          @persistence.transaction do |records, scope|
            capture_in(records.handoff_states.load_locked(@main_agent_id), scope).proof
          end
        end
      end

      def already_finalized?(before, current)
        old_route, route = before.routing, current.routing
        route.phase == "stable" && route.handoff_revision == old_route.handoff_revision + 1 &&
          route.to_h.except("phase", "handoff_revision", "updated_at") == old_route.to_h.except("phase", "handoff_revision", "updated_at") &&
          current.proof.except(:routing) == before.proof.except(:routing)
      end

      def capture_in(routing, scope)
        assert_store!
        unless routing && routing.active_agent_id == @target.agent_id && routing.pending_target_execution_id == @target.execution_id
          raise Phronomy::Persistence::StateConflictError, "Handoff no longer owns this pending Target"
        end
        source_agent_id = routing.metadata.fetch("source_agent_id")
        ids = [@main_agent_id, source_agent_id, @target.agent_id].uniq.sort
        @agent_store.guard_agents(scope, agent_ids: ids)
        source = @agent_store.observe_execution(agent_id: source_agent_id,
          execution_id: routing.pending_source_execution_id, scope: scope)
        target = @agent_store.observe_execution(agent_id: @target.agent_id, execution_id: @target.execution_id, scope: scope)
        assert_executions!(routing, source, target, scope)
        holds = ids.to_h { |id|
          [id, @agent_store.retained_references(agent_id: id, scope: scope).select { |hold| hold.owner_key == @owner_key }.map(&:to_h)
            .sort_by { |hold| Phronomy::CanonicalJSON.dump(hold) }]
        }
        assert_retention!(holds, source, target)
        proof = Phronomy::Values::Immutable.copy(routing: routing.to_h,
          source: execution_proof(source), target: execution_proof(target), holds: holds)
        Snapshot.new(routing: routing, source: source, target: target, proof: proof)
      end

      def assert_executions!(routing, source, target, scope)
        receipt = {"target_agent_id" => target.agent_id, "target_execution_id" => target.execution_id,
                   "context_ref" => routing.active_handoff_context_ref, "owner_key" => @owner_key}
        unless source.status == :handed_off && source.reservation&.correlation == @owner && source.transfer_receipt == receipt &&
            target.reservation&.correlation == @owner && STATUSES.include?(target.status) && execution_proof(target) == execution_proof(@target)
          raise Phronomy::Persistence::StateConflictError, "Handoff terminal Target or Source transfer identity differs"
        end
        unless @agent_store.active_executions(agent_id: target.agent_id, scope: scope).empty?
          raise Phronomy::AgentBusyError, "Handoff Target has another active execution"
        end
      end

      def assert_retention!(holds, source, target)
        [[@main_agent_id, nil], [source.agent_id, source.execution_id], [target.agent_id, target.execution_id]].each do |id, execution_id|
          unless holds.fetch(id).any? { |hold| hold.fetch("owner_key") == @owner_key && (!execution_id || hold["execution_id"] == execution_id) }
            raise Phronomy::Persistence::StateConflictError, "Handoff required Source, Target or anchor retention is absent"
          end
        end
      end

      def execution_proof(value)
        value.to_result.merge(reservation: value.reservation&.to_h,
          transfer_receipt: value.transfer_receipt, cancellation_requested: value.cancellation_requested)
      end

      def assert_store!
        unless @agent_store.execution_evidence_identity.equal?(@store_identity) &&
            @persistence.agent_store.equal?(@agent_store) && @persistence.coordinator.equal?(@agent_store.coordinator)
          raise Phronomy::Persistence::StateConflictError, "Handoff finalization belongs to another Store"
        end
      end

      def diagnostic(error, disposition: :not_attempted, read_error: nil)
        HandoffFinalizationError.new(main_agent_id: @main_agent_id, execution_id: @execution_id,
          execution_result: @target.to_result, execution_error: saved_execution_error, finalization_error: error,
          disposition: disposition, read_error: read_error)
      end

      # Ask Agent's public semantic value to restore its own error variants.
      def saved_execution_error
        @target.value!
        nil
      rescue => error
        error
      end
    end
  end
end
