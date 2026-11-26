# frozen_string_literal: true

require "digest"

module Phronomy
  module MultiAgent
    # Detached persistence plan for the native parent's dispatch participant.
    # It restores only the original opaque state and its own parent retention;
    # no participant, child admission, import callback or business work is replayed.
    # @api private
    class NativeDispatchEvidence
      attr_reader :agent_ids

      def self.capture(values:, persistence:, native_persistence:)
        unless native_persistence.agent_store.equal?(persistence) &&
            native_persistence.coordinator.equal?(persistence.coordinator)
          raise Phronomy::Persistence::StateConflictError, "Native dispatch proof belongs to another Store"
        end
        new(values, persistence.execution_evidence_identity, native_persistence)
      end

      def initialize(values, persistence_identity, native_persistence)
        @persistence_identity, @native_persistence = persistence_identity, native_persistence
        execution = values.fetch(:result)
        @agent_id, @execution_id = execution.agent_id, execution.execution_id
        before, after = values.fetch(:before), values.fetch(:after)
        before_binding = before.fetch(0).fetch(1).fetch("metadata").fetch("execution_extension")
        after_binding = after.fetch(0).fetch(1).fetch("metadata").fetch("execution_extension")
        [before_binding, after_binding].each do |binding|
          unless binding.fetch("binding_key") == DurableSubagentCoordinator::BINDING_KEY && binding.fetch("binding_version") == 1
            raise Phronomy::Persistence::StateConflictError, "Unsupported native dispatch binding"
          end
        end
        before_state = before.fetch(0).fetch(3) || {"children" => [], "cancel_requested" => false}
        after_state = after.fetch(0).fetch(3)
        @children = Phronomy::Values::Immutable.copy(after_state.fetch("children"))
        prior_children = before_state.fetch("children")
        validate_children!(prior_children)
        @prior_slots = prior_children.map { |child| child.fetch("slot") }.freeze
        @agent_ids = ([@agent_id] + @children.map { |child| child.fetch("agent_id") }).uniq.sort.freeze
        @reference = after_binding.fetch("state_ref").dup.freeze
        @bytes = Phronomy::CanonicalJSON.dump(after_state).b.freeze
        @canonicalization_version = Phronomy::CanonicalJSON::VERSION
        unless @reference == "sha256:#{Digest::SHA256.hexdigest(@bytes)}"
          raise Phronomy::Persistence::StateConflictError, "Native dispatch content differs from its captured reference"
        end
        @before_holds = Phronomy::Values::Immutable.copy(before.fetch(1))
        @after_holds = Phronomy::Values::Immutable.copy(after.fetch(1))
        expected = Phronomy::Agent::Retention.new(agent_id: @agent_id, execution_id: @execution_id,
          owner_key: "subagent:#{@execution_id}")
        additions = @after_holds - @before_holds
        replayable_holds = (@before_holds - @after_holds).empty? &&
          (additions.empty? || additions == [expected.to_h]) &&
          (@children.empty? || @after_holds.include?(expected.to_h))
        unless replayable_holds
          raise Phronomy::Persistence::StateConflictError, "Native dispatch retention change is not replayable"
        end
        @added_holds = additions.map { |hold| Phronomy::Agent::Retention.new(**hold.transform_keys(&:to_sym)) }.freeze
        freeze
      end
      private_class_method :new

      # Root guards require an existing record. New child absence is checked
      # authoritatively in this transaction, under the parent's original owner;
      # this does not create a cross-transaction reservation for an absent root.
      def guarded_agent_ids(persistence:, scope:)
        validate_store!(persistence)
        agent_ids.select { |id| id == @agent_id || read_root(persistence, scope, id) }
      end

      def read(persistence:, scope:)
        validate_store!(persistence)
        persistence.retained_references(agent_id: @agent_id, scope: scope).map(&:to_h)
      end

      def assert_retryable!(persistence:, scope:)
        validate_store!(persistence)
        assert_child_authority!(persistence, scope)
      end

      # A proven post-state does not establish current authority to start work.
      # Terminal child history is stable; unrelated holds and cancellation intent
      # do not revoke that history, while the required native hold must remain.
      def assert_continuable!(persistence:, scope:)
        validate_store!(persistence)
        @native_persistence.participate(scope) do |records|
          unless records.contents.fetch(@reference) == @bytes
            raise Phronomy::Persistence::StateConflictError, "Native dispatch content changed before continuation"
          end
        end
        assert_child_authority!(persistence, scope)
      end

      def replay(persistence:, scope:)
        validate_store!(persistence)
        @native_persistence.participate(scope) do |records|
          reference = records.contents.put(@bytes, canonicalization_version: @canonicalization_version)
          unless reference == @reference
            raise Phronomy::Persistence::StateConflictError, "Native dispatch content replay changed identity"
          end
        end
        @added_holds.each { |hold| persistence.retain(hold, scope: scope) }
        nil
      end

      private

      def validate_children!(prior_children)
        unless @children.map { |child| child.fetch("slot") }.uniq.size == @children.size &&
            @children.map { |child| child.fetch("agent_id") }.uniq.size == @children.size &&
            prior_children.size <= @children.size
          raise Phronomy::Persistence::StateConflictError, "Native dispatch child identities are not unique"
        end
        prior_children.each_with_index do |prior, index|
          current = @children.fetch(index)
          preserved = prior.except("imported") == current.except("imported") &&
            (!prior.fetch("imported") || current.fetch("imported"))
          unless preserved
            raise Phronomy::Persistence::StateConflictError, "Native dispatch replaced an existing child slot"
          end
        end
        @children.each do |child|
          digest = Digest::SHA256.hexdigest(Phronomy::CanonicalJSON.dump(
            ["phronomy-subagent-v1", @agent_id, @execution_id, child.fetch("slot")]
          ))
          unless child.fetch("agent_id") == "subagent-#{digest}" &&
              child.fetch("execution_id") == "subagent-execution-#{digest}"
            raise Phronomy::Persistence::StateConflictError, "Native dispatch child identity differs from its slot"
          end
        end
      end

      def assert_child_authority!(persistence, scope)
        @children.each do |child|
          id, execution_id = child.fetch("agent_id"), child.fetch("execution_id")
          root = read_root(persistence, scope, id)
          observed = persistence.observe_execution(agent_id: id, execution_id: execution_id, scope: scope)
          if !@prior_slots.include?(child.fetch("slot"))
            unless root.nil? && observed.absent?
              raise Phronomy::Persistence::StateConflictError, "Reserved native child appeared before dispatch continuation"
            end
            next
          end
          next if root.nil? && observed.absent? && !child.fetch("imported")

          owner = {"kind" => "subagent", "parent_agent_id" => @agent_id,
                   "parent_execution_id" => @execution_id, "slot" => child.fetch("slot")}
          reservation = Phronomy::Agent::ReservedExecution.new(agent_id: id,
            execution_id: execution_id, correlation: owner)
          definition = child.fetch("definition")
          hold = Phronomy::Agent::Retention.new(agent_id: id, execution_id: execution_id,
            owner_key: "subagent:#{@execution_id}")
          unless root && root.agent_definition_id == definition.fetch("id") &&
              root.agent_definition_version == definition.fetch("version") &&
              observed.terminal? && observed.reservation == reservation &&
              persistence.retained_references(agent_id: id, scope: scope).include?(hold)
            raise Phronomy::Persistence::StateConflictError, "Native child authority changed before dispatch continuation"
          end
        end
        nil
      end

      def read_root(persistence, scope, id)
        persistence.participate(scope) do |records|
          records.agents.load(id)
        rescue Phronomy::Persistence::NotFoundError
          nil
        end
      end

      def validate_store!(persistence)
        unless persistence.execution_evidence_identity.equal?(@persistence_identity) &&
            @native_persistence.agent_store.equal?(persistence) &&
            @native_persistence.coordinator.equal?(persistence.coordinator)
          raise Phronomy::Persistence::StateConflictError, "Native dispatch proof belongs to another Store"
        end
      end
    end
  end
end
