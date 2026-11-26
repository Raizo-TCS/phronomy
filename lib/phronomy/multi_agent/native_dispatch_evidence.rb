# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # Detached persistence plan for the native parent's dispatch participant.
    # It restores only the original opaque state and its own parent retention;
    # no participant, child admission, import callback or business work is replayed.
    # @api private
    class NativeDispatchEvidence
      def self.capture(values:, persistence:, native_persistence:, binding_key:)
        new(values, persistence, native_persistence, binding_key)
      end

      def initialize(values, persistence, native_persistence, binding_key)
        @plan = NativePersistencePlan.new(values: values, execution: values.fetch(:result),
          persistence: persistence, native_persistence: native_persistence, binding_key: binding_key)
        prior = @plan.prior_children
        preserved = prior.size <= @plan.children.size && prior.each_with_index.all? { |child, index|
          current = @plan.children.fetch(index)
          child.except("imported") == current.except("imported") && (!child.fetch("imported") || current.fetch("imported"))
        }
        unless preserved
          raise Phronomy::Persistence::StateConflictError, "Native dispatch replaced an existing child slot"
        end
        @authority = NativeChildAuthority.new(agent_id: @plan.agent_id, execution_id: @plan.execution_id,
          children: @plan.children, prior_slots: prior.map { |child| child.fetch("slot") }, persistence: persistence)
        freeze
      end
      private_class_method :new

      def agent_ids = @authority.agent_ids
      def guarded_agent_ids(persistence:, scope:) = @authority.guarded_agent_ids(persistence: persistence, scope: scope)
      def read(persistence:, scope:) = @plan.read(persistence: persistence, scope: scope)
      def replay(persistence:, scope:) = @plan.replay(persistence: persistence, scope: scope)
      def assert_retryable!(persistence:, scope:) = @authority.assert_current!(persistence: persistence, scope: scope)

      def assert_continuable!(persistence:, scope:)
        @plan.assert_content!(persistence: persistence, scope: scope)
        @authority.assert_current!(persistence: persistence, scope: scope)
      end
    end
  end
end
