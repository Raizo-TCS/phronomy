# frozen_string_literal: true

module Phronomy
  class Persistence
    # Runtime/domain-facing repositories layered over record-oriented Backend SPI
    # repositories. Backend implementations never receive AgentRoot,
    # AgentExecution, JournalRecord, or Workflow snapshot domain values directly.
    #
    # @api private
    module RepositoryFacades
      class Agents
        def initialize(backend_repository)
          @backend_repository = backend_repository
        end

        def create(root)
          record = DurableCodec.encode_agent_root(root)
          DurableCodec.decode_agent_root(@backend_repository.create(record))
        end

        def load(agent_id)
          DurableCodec.decode_agent_root(@backend_repository.load(agent_id.to_s))
        end

        def save(agent_id, expected_revision:, root:)
          record = DurableCodec.encode_agent_root(root)
          stored = @backend_repository.save(
            agent_id.to_s,
            expected_revision: Integer(expected_revision),
            record: record
          )
          DurableCodec.decode_agent_root(stored)
        end

        def delete(agent_id)
          @backend_repository.delete(agent_id.to_s)
        end
      end

      class Journals
        def initialize(backend_repository)
          @backend_repository = backend_repository
        end

        def append(agent_id, expected_position:, records:)
          expected = Integer(expected_position)
          sequenced = Array(records).each_with_index.map do |record, index|
            record.with_sequence(expected + index + 1)
          end
          encoded = sequenced.map { |record| DurableCodec.encode_journal_record(record) }
          @backend_repository.append(
            agent_id.to_s,
            expected_position: expected,
            records: encoded
          ).map { |record| DurableCodec.decode_journal_record(record) }.freeze
        end

        def read(agent_id, after: nil, limit: nil)
          @backend_repository.read(
            agent_id.to_s,
            after: after,
            limit: limit
          ).map { |record| DurableCodec.decode_journal_record(record) }.freeze
        end

        def head(agent_id)
          Integer(@backend_repository.head(agent_id.to_s))
        end

        def delete(agent_id)
          @backend_repository.delete(agent_id.to_s)
        end
      end

      class Executions
        def initialize(backend_repository)
          @backend_repository = backend_repository
        end

        def create_active(execution)
          record = DurableCodec.encode_agent_execution(execution)
          DurableCodec.decode_agent_execution(@backend_repository.create_active(record))
        end

        def load(execution_id)
          DurableCodec.decode_agent_execution(
            @backend_repository.load(execution_id.to_s)
          )
        end

        def save(execution_id, expected_revision:, execution:)
          record = DurableCodec.encode_agent_execution(execution)
          stored = @backend_repository.save(
            execution_id.to_s,
            expected_revision: Integer(expected_revision),
            record: record
          )
          DurableCodec.decode_agent_execution(stored)
        end

        def list_active(agent_id)
          @backend_repository.list_active(agent_id.to_s).map do |record|
            DurableCodec.decode_agent_execution(record)
          end.freeze
        end

        def delete(execution_id)
          @backend_repository.delete(execution_id.to_s)
        end

        def delete_for_agent(agent_id)
          @backend_repository.delete_for_agent(agent_id.to_s)
        end

        def assert_idle!(agent_id)
          @backend_repository.assert_idle!(agent_id.to_s)
        end
      end

      class WorkflowStates
        def initialize(backend_repository)
          @backend_repository = backend_repository
        end

        def load(workflow_instance_id)
          record = @backend_repository.load(workflow_instance_id.to_s)
          return nil unless record

          DurableCodec.decode_workflow_state(
            record,
            expected_workflow_instance_id: workflow_instance_id
          )
        end

        def save(workflow_instance_id, expected_revision:, snapshot:)
          next_revision = expected_revision.nil? ? 1 : Integer(expected_revision) + 1
          record = DurableCodec.encode_workflow_state(
            workflow_instance_id: workflow_instance_id,
            workflow_revision: next_revision,
            snapshot: snapshot
          )
          stored = @backend_repository.save(
            workflow_instance_id.to_s,
            expected_revision: expected_revision.nil? ? nil : Integer(expected_revision),
            record: record
          )
          decoded = DurableCodec.decode_workflow_state(
            stored,
            expected_workflow_instance_id: workflow_instance_id
          )
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
