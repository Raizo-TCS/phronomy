# frozen_string_literal: true

require "digest"

module Phronomy
  module MultiAgent
    # Routing and Agent terminal state share the same outer transaction. This
    # participant sees public semantic values only, never Agent records.
    # @api private
    class HandoffParticipant
      def initialize(persistence:, main_agent_id:, expected_revision:)
        @persistence, @main_agent_id, @expected_revision = persistence, main_agent_id, expected_revision
      end

      def binding
        Phronomy::Agent::ExecutionExtensionState.new(binding_key: "phronomy.handoff", binding_version: 1)
      end

      def guard_change(change, scope)
        @persistence.participate(scope) { |records| records.handoff_states.load_locked(@main_agent_id) }
        ids = [@main_agent_id, change.agent_id, change.control_request&.target_agent_id].compact
        @persistence.agent_store.guard_agents(scope, agent_ids: ids)
      end

      def change_evidence(change, scope)
        state = @persistence.participate(scope) { |records| records.handoff_states.load(@main_agent_id) }
        ids = [@main_agent_id, change.agent_id, change.control_request&.target_agent_id].compact.uniq.sort
        [state&.to_h, ids.map { |id| @persistence.agent_store.retained_references(agent_id: id, scope: scope).map(&:to_h) }]
      end

      def commit(change)
        @persistence.coordinator.atomic do |scope|
          guard_change(change, scope)
          change.prepare_in(scope)
          @persistence.participate(scope) do |records|
            routing = records.handoff_states.load(@main_agent_id)
            unless routing && routing.active_agent_id == change.agent_id
              raise Phronomy::Persistence::StateConflictError, "Handoff no longer owns this execution"
            end
            receipt = nil
            if change.kind == :terminal && change.control_request
              if Array(routing.metadata["cancelled_execution_ids"]).include?(change.execution_id) || change.cancel_requested
                raise Phronomy::CancellationError, "Handoff Source turn was cancelled"
              end
              unless routing.handoff_revision == @expected_revision
                raise Phronomy::Persistence::StateConflictError, "Handoff routing changed before Source transfer"
              end
              request = change.control_request
              context = change.transfer_context(scope)
              ref = records.contents.put_json(context.to_h)
              target_id = "handoff-target-#{Digest::SHA256.hexdigest([change.execution_id, request.target_agent_id].join("\0"))}"
              definition = @persistence.agent_store.definition(agent_id: request.target_agent_id, scope: scope)
              retain(scope, change.agent_id, change.execution_id)
              retain(scope, request.target_agent_id, target_id)
              receipt = {"target_agent_id" => request.target_agent_id, "target_execution_id" => target_id,
                         "context_ref" => ref, "owner_key" => "handoff:#{@main_agent_id}"}.freeze
              ids = (Array(routing.metadata["retained_agent_ids"]) + [change.agent_id, request.target_agent_id]).uniq.sort
              transfer = routing.with(active_agent_id: request.target_agent_id, active_handoff_context_ref: ref,
                phase: "target_pending", pending_source_execution_id: change.execution_id, pending_target_execution_id: target_id,
                metadata: routing.metadata.merge("target_definition" => definition.transform_keys(&:to_s),
                  "source_agent_id" => change.agent_id, "retained_agent_ids" => ids))
              records.handoff_states.save(@main_agent_id, expected_revision: routing.handoff_revision, state: transfer)
            elsif change.finishing? && routing.phase != "stable" && routing.pending_target_execution_id == change.execution_id
              records.handoff_states.save(@main_agent_id, expected_revision: routing.handoff_revision, state: routing.with(phase: "stable"))
            end
            change.commit_in(scope, transfer_receipt: receipt)
          end
        end
      end

      private

      def retain(scope, id, execution_id)
        @persistence.agent_store.retain(Phronomy::Agent::Retention.new(agent_id: id, execution_id: execution_id,
          owner_key: "handoff:#{@main_agent_id}"), scope: scope)
      end
    end
  end
end
