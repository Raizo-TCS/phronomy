# frozen_string_literal: true

module Phronomy
  class Persistence
    # Runtime/domain-facing repositories layered over record-oriented Backend SPI
    # repositories. Backend implementations never receive AgentRoot,
    # AgentExecution, JournalRecord, or Workflow snapshot domain values directly.
    #
    # Backend repositories receive DurableRecord plus explicit identity/revision/
    # admission metadata needed for indexing and compare-and-swap. They must not
    # inspect DurableRecord#payload to rediscover those semantics.
    #
    # @api private
    module RepositoryFacades
      class Agents
        def initialize(backend_repository)
          @backend_repository = backend_repository
        end

        def create(root)
          record = DurableCodec.encode_agent_root(root)
          stored = @backend_repository.create(
            agent_id: root.agent_id.to_s,
            agent_revision: Integer(root.agent_revision),
            record: record
          )
          decode_for_agent(stored, root.agent_id, revision: root.agent_revision)
        end

        def load(agent_id)
          decode_for_agent(@backend_repository.load(agent_id.to_s), agent_id)
        end

        def save(agent_id, expected_revision:, root:)
          expected = Integer(expected_revision)
          next_revision = Integer(root.agent_revision)
          unless next_revision == expected + 1
            raise Phronomy::Persistence::ConflictError,
              "agent save must advance revision exactly once: " \
              "expected #{expected + 1}, got #{next_revision}"
          end
          unless root.agent_id.to_s == agent_id.to_s
            raise Phronomy::Persistence::SerializationError,
              "Agent root identity mismatch: #{root.agent_id} != #{agent_id}"
          end

          record = DurableCodec.encode_agent_root(root)
          stored = @backend_repository.save(
            agent_id.to_s,
            expected_revision: expected,
            next_revision: next_revision,
            record: record
          )
          decode_for_agent(stored, agent_id, revision: next_revision)
        end

        def delete(agent_id)
          @backend_repository.delete(agent_id.to_s)
        end

        private

        def decode_for_agent(record, agent_id, revision: nil)
          root = DurableCodec.decode_agent_root(record)
          unless root.agent_id == agent_id.to_s
            raise Phronomy::Persistence::SerializationError,
              "backend returned Agent root for #{root.agent_id.inspect}; expected #{agent_id.to_s.inspect}"
          end
          if revision && root.agent_revision != revision
            raise Phronomy::Persistence::SerializationError,
              "backend returned Agent revision #{root.agent_revision}; expected #{revision}"
          end
          root
        end
      end

      class Journals
        def initialize(backend_repository)
          @backend_repository = backend_repository
        end

        def append(agent_id, expected_position:, records:)
          expected = Integer(expected_position)
          sequenced = Array(records).each_with_index.map do |record, index|
            unless record.agent_id.to_s == agent_id.to_s
              raise Phronomy::Persistence::SerializationError,
                "Journal record Agent mismatch: #{record.agent_id} != #{agent_id}"
            end
            record.with_sequence(expected + index + 1)
          end
          encoded = sequenced.map { |record| DurableCodec.encode_journal_record(record) }
          stored = @backend_repository.append(
            agent_id.to_s,
            expected_position: expected,
            records: encoded,
            record_ids: sequenced.map { |record| record.record_id.to_s }.freeze
          )
          decoded = Array(stored).map { |record| DurableCodec.decode_journal_record(record) }
          validate_read!(decoded, agent_id, start_sequence: expected + 1)
        end

        def read(agent_id, after: nil, limit: nil)
          after_value = after.nil? ? nil : Integer(after)
          limit_value = limit.nil? ? nil : Integer(limit)
          stored = @backend_repository.read(
            agent_id.to_s,
            after: after_value,
            limit: limit_value
          )
          decoded = Array(stored).map { |record| DurableCodec.decode_journal_record(record) }
          validate_read!(decoded, agent_id, start_sequence: (after_value || 0) + 1)
        end

        def head(agent_id)
          Integer(@backend_repository.head(agent_id.to_s))
        end

        def delete(agent_id)
          @backend_repository.delete(agent_id.to_s)
        end

        private

        def validate_read!(records, agent_id, start_sequence:)
          records.each_with_index do |record, index|
            unless record.agent_id == agent_id.to_s
              raise Phronomy::Persistence::SerializationError,
                "backend returned Journal record for #{record.agent_id.inspect}; expected #{agent_id.to_s.inspect}"
            end
            expected_sequence = start_sequence + index
            unless record.sequence == expected_sequence
              raise Phronomy::Persistence::SerializationError,
                "backend returned Journal sequence #{record.sequence.inspect}; expected #{expected_sequence}"
            end
          end
          records.freeze
        end
      end

      class Executions
        def initialize(backend_repository)
          @backend_repository = backend_repository
        end

        def create_active(execution)
          unless execution.active?
            raise Phronomy::Persistence::SerializationError,
              "create_active requires an active AgentExecution"
          end
          record = DurableCodec.encode_agent_execution(execution)
          stored = @backend_repository.create_active(
            execution_id: execution.execution_id.to_s,
            agent_id: execution.agent_id.to_s,
            execution_revision: Integer(execution.execution_revision),
            record: record
          )
          decode_for_execution(
            stored,
            execution.execution_id,
            agent_id: execution.agent_id,
            revision: execution.execution_revision,
            active: true
          )
        end

        def load(execution_id)
          decode_for_execution(@backend_repository.load(execution_id.to_s), execution_id)
        end

        def save(execution_id, expected_revision:, execution:)
          expected = Integer(expected_revision)
          next_revision = Integer(execution.execution_revision)
          unless next_revision == expected + 1
            raise Phronomy::Persistence::ConflictError,
              "execution save must advance revision exactly once: " \
              "expected #{expected + 1}, got #{next_revision}"
          end
          unless execution.execution_id.to_s == execution_id.to_s
            raise Phronomy::Persistence::SerializationError,
              "Execution identity mismatch: #{execution.execution_id} != #{execution_id}"
          end

          record = DurableCodec.encode_agent_execution(execution)
          stored = @backend_repository.save(
            execution_id.to_s,
            expected_revision: expected,
            next_revision: next_revision,
            agent_id: execution.agent_id.to_s,
            active: execution.active?,
            record: record
          )
          decode_for_execution(
            stored,
            execution_id,
            agent_id: execution.agent_id,
            revision: next_revision,
            active: execution.active?
          )
        end

        def list_active(agent_id)
          Array(@backend_repository.list_active(agent_id.to_s)).map do |record|
            decode_for_execution(record, nil, agent_id: agent_id, active: true)
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

        private

        def decode_for_execution(record, execution_id, agent_id: nil, revision: nil, active: nil)
          execution = DurableCodec.decode_agent_execution(record)
          if execution_id && execution.execution_id != execution_id.to_s
            raise Phronomy::Persistence::SerializationError,
              "backend returned Execution #{execution.execution_id.inspect}; expected #{execution_id.to_s.inspect}"
          end
          if agent_id && execution.agent_id != agent_id.to_s
            raise Phronomy::Persistence::SerializationError,
              "backend returned Execution for Agent #{execution.agent_id.inspect}; expected #{agent_id.to_s.inspect}"
          end
          if revision && execution.execution_revision != revision
            raise Phronomy::Persistence::SerializationError,
              "backend returned Execution revision #{execution.execution_revision}; expected #{revision}"
          end
          if !active.nil? && execution.active? != active
            raise Phronomy::Persistence::SerializationError,
              "backend returned Execution active=#{execution.active?}; expected #{active}"
          end
          execution
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
          expected = expected_revision.nil? ? nil : Integer(expected_revision)
          next_revision = expected.nil? ? 1 : expected + 1
          record = DurableCodec.encode_workflow_state(
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
          decoded = DurableCodec.decode_workflow_state(
            stored,
            expected_workflow_instance_id: workflow_instance_id
          )
          unless decoded.fetch(:revision) == next_revision
            raise Phronomy::Persistence::SerializationError,
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

      # Transaction-scoped domain-facing Persistence view built from raw backend
      # repositories. Backend implementations can use this through
      # Persistence#build_transaction_view without duplicating facade logic.
      class View
        attr_reader :contents, :agents, :journals, :executions, :workflow_states

        def initialize(contents:, agents:, journals:, executions:, workflow_states:, watermark:)
          @contents = contents
          @agents = Agents.new(agents)
          @journals = Journals.new(journals)
          @executions = Executions.new(executions)
          @workflow_states = WorkflowStates.new(workflow_states)
          @watermark = watermark
        end

        def assert_agent_watermark!(agent_id:, agent_revision:, journal_position:)
          @watermark.assert_agent_watermark!(
            agent_id: agent_id.to_s,
            agent_revision: Integer(agent_revision),
            journal_position: Integer(journal_position)
          )
        end
      end
    end
  end
end
