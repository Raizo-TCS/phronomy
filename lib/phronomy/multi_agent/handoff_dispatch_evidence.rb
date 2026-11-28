# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # Detached routing and retention facts for one Handoff-owned Agent dispatch.
    # Agent owns the execution write; this adapter preserves Handoff authority
    # without replaying its participant, a transfer, or Target admission.
    # @api private
    class HandoffDispatchEvidence
      def self.capture(values:, persistence:, handoff_persistence:, main_agent_id:, expected_revision:, binding_key:)
        new(values, persistence, handoff_persistence, main_agent_id, expected_revision, binding_key)
      end

      def initialize(values, persistence, handoff_persistence, main_agent_id, expected_revision, binding_key)
        @persistence_identity = persistence.execution_evidence_identity
        @handoff_persistence = handoff_persistence
        @main_agent_id = main_agent_id.to_s.dup.freeze
        @expected_revision = expected_revision
        @binding_key = binding_key.to_s.dup.freeze
        execution = values.fetch(:result)
        @agent_id, @execution_id = execution.agent_id, execution.execution_id
        @owner = {"kind" => "handoff", "main_agent_id" => @main_agent_id}.freeze
        @owner_key = "handoff:#{@main_agent_id}".freeze
        validate_store!(persistence)
        capture_participation!(values)
        validate_execution!(values.fetch(:before).fetch(0).fetch(1))
        validate_execution!(values.fetch(:after).fetch(0).fetch(1))
        unless values.fetch(:after).fetch(0).fetch(1) == execution.to_h
          raise Phronomy::Persistence::StateConflictError, "Handoff dispatch result differs from captured execution"
        end
        freeze
      end
      private_class_method :new

      # Match admission, cancellation and commit: routing before Agent guards.
      def guarded_agent_ids(persistence:, scope:)
        validate_store!(persistence)
        @handoff_persistence.participate(scope) { |records| records.handoff_states.load_locked(@main_agent_id) }
        @agent_ids
      end

      def read(persistence:, scope:)
        validate_store!(persistence)
        routing = @handoff_persistence.participate(scope) { |records| records.handoff_states.load(@main_agent_id) }
        [routing&.to_h, @agent_ids.map { |id|
          persistence.retained_references(agent_id: id, scope: scope).map(&:to_h)
            .sort_by { |hold| Phronomy::CanonicalJSON.dump(hold) }
        }]
      end

      # The caller first asserts retry authority in the same guarded scope.
      # Dispatch changes no Handoff records; retry writes only Agent's proof.
      def replay(persistence:, scope:)
        validate_store!(persistence)
        nil
      end

      def assert_retryable!(persistence:, scope:)
        assert_current!(persistence: persistence, scope: scope)
      end

      def assert_continuable!(persistence:, scope:)
        assert_current!(persistence: persistence, scope: scope)
      end

      private

      def capture_participation!(values)
        before, after = values.fetch(:before).fetch(1), values.fetch(:after).fetch(1)
        unless before == after && before.is_a?(Array) && before.length == 2
          raise Phronomy::Persistence::StateConflictError, "Handoff dispatch changed its participant footprint"
        end
        @participation = Phronomy::Values::Immutable.copy(before)
        @routing = HandoffState.from_h(@participation.fetch(0))
        unless @routing.main_agent_id == @main_agent_id
          raise Phronomy::Persistence::StateConflictError, "Handoff dispatch belongs to another anchor"
        end
        ids = [@main_agent_id, @agent_id]
        ids << @routing.metadata["source_agent_id"] unless @routing.phase == "stable"
        @agent_ids = ids.compact.uniq.sort.freeze
        unless @participation.fetch(1).is_a?(Array) && @participation.fetch(1).length == @agent_ids.length
          raise Phronomy::Persistence::StateConflictError, "Handoff dispatch retention footprint is incomplete"
        end
        @agent_ids.zip(@participation.fetch(1)).each do |id, holds|
          unless holds.is_a?(Array) && holds.all? { |hold| hold.fetch("agent_id") == id }
            raise Phronomy::Persistence::StateConflictError, "Handoff dispatch retention identities differ"
          end
        end
      end

      def validate_execution!(execution)
        metadata = execution.fetch("metadata")
        binding = metadata.fetch("execution_extension")
        unless execution.fetch("agent_id") == @agent_id && execution.fetch("execution_id") == @execution_id &&
            binding.fetch("binding_key") == @binding_key && binding.fetch("binding_version") == 1 &&
            metadata["reservation"] == @owner
          raise Phronomy::Persistence::StateConflictError, "Handoff dispatch execution identity or binding differs"
        end
      end

      def assert_current!(persistence:, scope:)
        unless read(persistence: persistence, scope: scope) == @participation
          raise Phronomy::Persistence::StateConflictError, "Handoff routing or retention changed before dispatch"
        end
        assert_route!
        assert_execution!(persistence, scope)
        assert_retention!
        assert_target!(persistence, scope) unless @routing.phase == "stable"
        nil
      end

      def assert_route!
        current = @routing.active_agent_id == @agent_id && @routing.handoff_revision == @expected_revision &&
          (@routing.phase == "stable" || @routing.pending_target_execution_id == @execution_id)
        unless current
          raise Phronomy::Persistence::StateConflictError, "Handoff no longer owns this exact dispatch"
        end
      end

      def assert_execution!(persistence, scope)
        observed = persistence.observe_execution(agent_id: @agent_id, execution_id: @execution_id, scope: scope)
        reservation = Phronomy::Agent::ReservedExecution.new(agent_id: @agent_id,
          execution_id: @execution_id, correlation: @owner)
        unless observed.status == :active && observed.reservation == reservation
          raise Phronomy::Persistence::StateConflictError, "Handoff dispatch reservation is no longer active"
        end
        if observed.cancellation_requested || Array(@routing.metadata["cancelled_execution_ids"]).include?(@execution_id)
          raise Phronomy::CancellationError, "Handoff dispatch was cancelled"
        end
      end

      def assert_retention!
        @agent_ids.zip(@participation.fetch(1)).each do |id, holds|
          exact_target = id == @agent_id && @routing.phase != "stable"
          unless holds.any? { |hold|
            hold.fetch("owner_key") == @owner_key &&
                (!exact_target || hold["execution_id"] == @execution_id)
          }
            raise Phronomy::Persistence::StateConflictError, "Handoff dispatch required retention is absent"
          end
          exact_source = id == @routing.metadata["source_agent_id"] && @routing.phase != "stable"
          if exact_source && holds.none? { |hold|
            hold.fetch("owner_key") == @owner_key && hold["execution_id"] == @routing.pending_source_execution_id
          }
            raise Phronomy::Persistence::StateConflictError, "Handoff Source transfer retention is absent"
          end
        end
      end

      def assert_target!(persistence, scope)
        definition = persistence.definition(agent_id: @agent_id, scope: scope).transform_keys(&:to_s)
        unless definition == @routing.metadata["target_definition"]
          raise Phronomy::Persistence::StateConflictError, "Handoff Target definition changed before dispatch"
        end
        source_id = @routing.pending_source_execution_id
        identity = persistence.execution_identity(source_id, scope: scope)
        source = persistence.observe_execution(agent_id: identity.agent_id, execution_id: source_id, scope: scope)
        receipt = source.transfer_receipt
        unless identity.correlation == @owner && identity.agent_id == @routing.metadata["source_agent_id"] &&
            source.status == :handed_off && receipt && receipt["target_agent_id"] == @agent_id &&
            receipt["target_execution_id"] == @execution_id && receipt["context_ref"] == @routing.active_handoff_context_ref &&
            receipt["owner_key"] == @owner_key
          raise Phronomy::Persistence::StateConflictError, "Handoff Target no longer matches its Source transfer"
        end
      end

      def validate_store!(persistence)
        unless persistence.execution_evidence_identity.equal?(@persistence_identity) &&
            @handoff_persistence.agent_store.equal?(persistence) &&
            @handoff_persistence.coordinator.equal?(persistence.coordinator)
          raise Phronomy::Persistence::StateConflictError, "Handoff dispatch proof belongs to another Store"
        end
      end
    end
  end
end
