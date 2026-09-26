# frozen_string_literal: true

module Phronomy
  class Workflow
    module Persistence
      # Owns Workflow snapshot encoding and the initial revision.
      # @api private
      class StateRepository
        def initialize(view) = @view = view

        def load(workflow_instance_id)
          Phronomy::Persistence::StorageBoundary.call do
            @view.atomic do |bound|
              entry = bound.records(Phronomy::WorkflowStorageSchema::STATES).read(workflow_instance_id.to_s)
              entry && decode(entry, workflow_instance_id)
            end
          end
        end

        def save(workflow_instance_id, expected_revision:, snapshot:)
          Phronomy::Persistence::StorageBoundary.call do
            expected = expected_revision.nil? ? nil : Integer(expected_revision)
            revision = expected.nil? ? 1 : expected + 1
            record = Codec.encode_workflow_state(workflow_instance_id: workflow_instance_id,
              workflow_revision: revision, snapshot: snapshot)
            @view.atomic do |bound|
              records = bound.records(Phronomy::WorkflowStorageSchema::STATES)
              values = {key: workflow_instance_id.to_s, attributes: {}, record: record}
              entry = if expected.nil?
                records.insert(**values, revision: revision)
              else
                records.replace(**values, expected_revision: expected, next_revision: revision)
              end
              decoded = decode(entry, workflow_instance_id)
              unless decoded.fetch(:revision) == revision
                raise Phronomy::Storage::SerializationError, "backend returned another Workflow revision"
              end
              revision
            end
          rescue Phronomy::Storage::NotFoundError => error
            raise Phronomy::Storage::ConflictError, error.message
          end
        end

        def delete(workflow_instance_id, expected_revision:)
          Phronomy::Persistence::StorageBoundary.call do
            @view.records(Phronomy::WorkflowStorageSchema::STATES).delete(key: workflow_instance_id.to_s, expected_revision: Integer(expected_revision))
          end
        end

        private

        def decode(entry, workflow_instance_id)
          decoded = Codec.decode_workflow_state(entry.record, expected_workflow_instance_id: workflow_instance_id)
          unless entry.key == workflow_instance_id.to_s && decoded.fetch(:revision) == entry.revision
            raise Phronomy::Storage::SerializationError, "backend returned another Workflow identity/revision"
          end
          decoded
        end
      end
    end
  end
end
