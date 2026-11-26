# frozen_string_literal: true

require "digest"

module Phronomy
  module MultiAgent
    # Captured native extension and parent retention writes. Domain adapters
    # decide whether the captured relationships permit replay or continuation.
    # @api private
    class NativePersistencePlan
      attr_reader :agent_id, :execution_id, :children, :prior_children

      def initialize(values:, execution:, persistence:, native_persistence:, binding_key:)
        @persistence_identity, @native_persistence = persistence.execution_evidence_identity, native_persistence
        validate_store!(persistence)
        @agent_id, @execution_id = execution.agent_id, execution.execution_id
        before, after = values.fetch(:before), values.fetch(:after)
        before_binding = before.fetch(0).fetch(1).fetch("metadata").fetch("execution_extension")
        after_binding = after.fetch(0).fetch(1).fetch("metadata").fetch("execution_extension")
        [before_binding, after_binding].each do |binding|
          unless binding.fetch("binding_key") == binding_key && binding.fetch("binding_version") == 1
            raise Phronomy::Persistence::StateConflictError, "Unsupported native persistence binding"
          end
        end
        before_state = before.fetch(0).fetch(3) || {"children" => [], "cancel_requested" => false}
        after_state = after.fetch(0).fetch(3)
        @children = Phronomy::Values::Immutable.copy(after_state.fetch("children"))
        @prior_children = Phronomy::Values::Immutable.copy(before_state.fetch("children"))
        @reference = after_binding.fetch("state_ref").dup.freeze
        @bytes = Phronomy::CanonicalJSON.dump(after_state).b.freeze
        @canonicalization_version = Phronomy::CanonicalJSON::VERSION
        unless @reference == "sha256:#{Digest::SHA256.hexdigest(@bytes)}"
          raise Phronomy::Persistence::StateConflictError, "Native persistence content differs from its captured reference"
        end
        before_holds = Phronomy::Values::Immutable.copy(before.fetch(1))
        after_holds = Phronomy::Values::Immutable.copy(after.fetch(1))
        expected = Phronomy::Agent::Retention.new(agent_id: agent_id, execution_id: execution_id,
          owner_key: "subagent:#{execution_id}")
        additions = after_holds - before_holds
        replayable = (before_holds - after_holds).empty? &&
          (additions.empty? || additions == [expected.to_h]) &&
          (children.empty? || after_holds.include?(expected.to_h))
        unless replayable
          raise Phronomy::Persistence::StateConflictError, "Native persistence retention change is not replayable"
        end
        @added_holds = additions.map { |hold| Phronomy::Agent::Retention.new(**hold.transform_keys(&:to_sym)) }.freeze
        freeze
      end

      def read(persistence:, scope:)
        validate_store!(persistence)
        persistence.retained_references(agent_id: agent_id, scope: scope).map(&:to_h)
      end

      def assert_content!(persistence:, scope:)
        validate_store!(persistence)
        @native_persistence.participate(scope) do |records|
          unless records.contents.fetch(@reference) == @bytes
            raise Phronomy::Persistence::StateConflictError, "Native persistence content differs from its captured bytes"
          end
        end
      end

      def replay(persistence:, scope:)
        validate_store!(persistence)
        @native_persistence.participate(scope) do |records|
          reference = records.contents.put(@bytes, canonicalization_version: @canonicalization_version)
          unless reference == @reference
            raise Phronomy::Persistence::StateConflictError, "Native persistence replay changed content identity"
          end
        end
        @added_holds.each { |hold| persistence.retain(hold, scope: scope) }
        nil
      end

      private

      def validate_store!(persistence)
        unless persistence.execution_evidence_identity.equal?(@persistence_identity) &&
            @native_persistence.agent_store.equal?(persistence) &&
            @native_persistence.coordinator.equal?(persistence.coordinator)
          raise Phronomy::Persistence::StateConflictError, "Native persistence proof belongs to another Store"
        end
      end
    end
  end
end
