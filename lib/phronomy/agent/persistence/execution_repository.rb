# frozen_string_literal: true

module Phronomy
  module Agent
    module Persistence
      # Domain repository over a raw repository in the selected storage transaction.
      # @api private
      class ExecutionRepository
        def initialize(backend_repository)
          @backend_repository = backend_repository
        end

        def create_active(execution)
          unless execution.active?
            raise Phronomy::Storage::SerializationError,
              "create_active requires an active AgentExecution"
          end
          record = Codec.encode_agent_execution(execution)
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
            raise Phronomy::Storage::ConflictError,
              "execution save must advance revision exactly once: " \
              "expected #{expected + 1}, got #{next_revision}"
          end
          unless execution.execution_id.to_s == execution_id.to_s
            raise Phronomy::Storage::SerializationError,
              "Execution identity mismatch: #{execution.execution_id} != #{execution_id}"
          end

          record = Codec.encode_agent_execution(execution)
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

        def list(agent_id, after: nil, limit: 100)
          raise ArgumentError, "limit must be a positive Integer" unless limit.is_a?(Integer) && limit.positive?
          Array(@backend_repository.list(agent_id.to_s, after: after&.to_s, limit: limit)).map do |record|
            decode_for_execution(record, nil, agent_id: agent_id)
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
          execution = Codec.decode_agent_execution(record)
          if execution_id && execution.execution_id != execution_id.to_s
            raise Phronomy::Storage::SerializationError,
              "backend returned Execution #{execution.execution_id.inspect}; expected #{execution_id.to_s.inspect}"
          end
          if agent_id && execution.agent_id != agent_id.to_s
            raise Phronomy::Storage::SerializationError,
              "backend returned Execution for Agent #{execution.agent_id.inspect}; expected #{agent_id.to_s.inspect}"
          end
          if revision && execution.execution_revision != revision
            raise Phronomy::Storage::SerializationError,
              "backend returned Execution revision #{execution.execution_revision}; expected #{revision}"
          end
          if !active.nil? && execution.active? != active
            raise Phronomy::Storage::SerializationError,
              "backend returned Execution active=#{execution.active?}; expected #{active}"
          end
          execution
        end
      end
    end
  end
end
