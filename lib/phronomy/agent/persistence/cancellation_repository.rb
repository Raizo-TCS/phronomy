# frozen_string_literal: true

module Phronomy
  module Agent
    module Persistence
      # Cancellation is monotonic and independent of the in-flight execution
      # revision. Recording intent cannot invalidate a worker's captured base.
      # @api private
      class CancellationRepository
        include Phronomy::Storage::RecordCodec

        def initialize(view) = @view = view

        def requested?(agent_id, execution_id)
          Phronomy::Persistence::StorageBoundary.call do
            @view.atomic do |view|
              entry = view.records(StorageSchema::CANCELLATIONS).read(execution_id)
              next false unless entry
              payload = current_payload!(entry.record, record_type: "phronomy.agent_cancellation", format_version: "0.1",
                keys: %w[agent_id execution_id], label: "Agent cancellation")
              unless payload == {"agent_id" => agent_id, "execution_id" => execution_id} && entry.attributes == {owner: agent_id}
                raise Phronomy::Storage::SerializationError, "Cancellation owner mismatch"
              end
              true
            end
          end
        end

        def request(agent_id, execution_id)
          Phronomy::Persistence::StorageBoundary.call do
            @view.atomic do |view|
              view.check!(guards: [Phronomy::Storage::GuardRef.new(resource: StorageSchema::ROOTS, key: agent_id)], conditions: [])
              unless self.class.new(view).requested?(agent_id, execution_id)
                view.records(StorageSchema::CANCELLATIONS).insert(key: execution_id, revision: 0,
                  attributes: {owner: agent_id}, record: build_record("phronomy.agent_cancellation", "0.1",
                    {"agent_id" => agent_id, "execution_id" => execution_id}))
              end
            end
          end
          true
        end

        def delete_for_agent(agent_id)
          Phronomy::Persistence::StorageBoundary.call do
            @view.records(StorageSchema::CANCELLATIONS).delete_matching(index: :owner, equals: {owner: agent_id})
          end
        end
      end
    end
  end
end
