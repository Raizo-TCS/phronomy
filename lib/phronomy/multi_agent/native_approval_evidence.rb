# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # Read-only native authority for an approval decision on the parent itself.
    # The Agent decision proof already contains its extension and retention set.
    # @api private
    class NativeApprovalEvidence
      def self.capture(execution:, persistence:, native_persistence:, binding_key:)
        unless native_persistence.agent_store.equal?(persistence) &&
            native_persistence.coordinator.equal?(persistence.coordinator)
          raise Phronomy::Persistence::StateConflictError, "Native approval proof belongs to another Store"
        end
        binding = execution.metadata.fetch("execution_extension")
        unless binding.fetch("binding_key") == binding_key && binding.fetch("binding_version") == 1
          raise Phronomy::Persistence::StateConflictError, "Unsupported native approval binding"
        end
        reference = binding["state_ref"]
        snapshot = reference ? native_persistence.contents.fetch_json(reference) : {"children" => []}
        children = snapshot.fetch("children")
        NativeChildAuthority.new(agent_id: execution.agent_id, execution_id: execution.execution_id,
          children: children, prior_slots: children.map { |child| child.fetch("slot") }, persistence: persistence)
      end
    end
  end
end
