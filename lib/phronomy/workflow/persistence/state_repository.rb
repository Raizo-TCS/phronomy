# frozen_string_literal: true

module Phronomy
  class Workflow
    module Persistence
      # Domain repository over a raw repository in the selected storage transaction.
      # @api private
      class StateRepository
        def initialize(backend_repository)
          @backend_repository = backend_repository
        end

        def load(workflow_instance_id)
          record = @backend_repository.load(workflow_instance_id.to_s)
          return nil unless record

          Codec.decode_workflow_state(
            record,
            expected_workflow_instance_id: workflow_instance_id
          )
        end

        def save(workflow_instance_id, expected_revision:, snapshot:)
          expected = expected_revision.nil? ? nil : Integer(expected_revision)
          next_revision = expected.nil? ? 1 : expected + 1
          record = Codec.encode_workflow_state(
            workflow_instance_id: workflow_instance_id,
            workflow_revision: next_revision,
            snapshot: snapshot
          )
          stored = @backend_repository.save(
            workflow_instance_id.to_s,
            expected_revision: expected,
            next_revision: next_revision,
            record: record
          )
          decoded = Codec.decode_workflow_state(
            stored,
            expected_workflow_instance_id: workflow_instance_id
          )
          unless decoded.fetch(:revision) == next_revision
            raise Phronomy::Storage::SerializationError,
              "backend returned Workflow revision #{decoded.fetch(:revision)}; expected #{next_revision}"
          end
          decoded.fetch(:revision)
        end

        def delete(workflow_instance_id, expected_revision:)
          @backend_repository.delete(
            workflow_instance_id.to_s,
            expected_revision: Integer(expected_revision)
          )
        end
      end
    end
  end
end
