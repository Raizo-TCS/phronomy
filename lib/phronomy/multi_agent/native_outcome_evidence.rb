# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # Captured native participant writes for an actual final outcome or wait.
    # Child progress can continue while the same parent outcome is reconciled.
    # Publishing these saved facts does not admit Provider or Tool work.
    # @api private
    class NativeOutcomeEvidence
      def self.capture(values:, persistence:, native_persistence:, binding_key:)
        new(values, persistence, native_persistence, binding_key)
      end

      def initialize(values, persistence, native_persistence, binding_key)
        @plan = NativePersistencePlan.new(values: values, execution: values.fetch(:result).execution,
          persistence: persistence, native_persistence: native_persistence, binding_key: binding_key)
        prior = @plan.prior_children
        preserved = prior.size == @plan.children.size && prior.each_with_index.all? { |child, index|
          current = @plan.children.fetch(index)
          child.except("terminal_acknowledgement") == current.except("terminal_acknowledgement") &&
            (!child["terminal_acknowledgement"] || child["terminal_acknowledgement"] == current["terminal_acknowledgement"])
        }
        unless preserved
          raise Phronomy::Persistence::StateConflictError, "Native outcome replaced an existing child slot"
        end
        @authority = NativeChildAuthority.new(agent_id: @plan.agent_id, execution_id: @plan.execution_id,
          children: @plan.children, prior_slots: prior.map { |child| child.fetch("slot") }, persistence: persistence)
        freeze
      end
      private_class_method :new

      def guarded_agent_ids(persistence:, scope:) = @authority.guarded_agent_ids(persistence: persistence, scope: scope)
      def read(persistence:, scope:) = @plan.read(persistence: persistence, scope: scope)
      def replay(persistence:, scope:) = @plan.replay(persistence: persistence, scope: scope)
      def assert_content!(persistence:, scope:) = @plan.assert_content!(persistence: persistence, scope: scope)
      def assert_retryable!(persistence:, scope:) = @authority.assert_current!(persistence: persistence, scope: scope, outcome: true)
    end
  end
end
