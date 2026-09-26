# frozen_string_literal: true

module Phronomy
  module Agent
    module Persistence
      # Owns execution activity, ownership, admission and durable record encoding.
      # @api private
      class ExecutionRepository
        def initialize(view) = @view = view

        def create_active(execution)
          Phronomy::Persistence::StorageBoundary.call do
            raise Phronomy::Storage::SerializationError, "create_active requires an active AgentExecution" unless execution.active?
            record = Codec.encode_agent_execution(execution)
            admission do
              @view.atomic do |bound|
                entry = bound.records(StorageSchema::EXECUTIONS).insert(key: execution.execution_id.to_s,
                  revision: Integer(execution.execution_revision), attributes: attributes(execution), record: record)
                decode(entry, execution.execution_id, owner: execution.agent_id,
                  revision: execution.execution_revision, active: true)
              end
            end
          end
        end

        def load(execution_id)
          Phronomy::Persistence::StorageBoundary.call do
            value = @view.atomic do |bound|
              entry = bound.records(StorageSchema::EXECUTIONS).read(execution_id.to_s)
              entry && decode(entry, execution_id)
            end
            value || raise(Phronomy::Storage::NotFoundError, "Execution not found: #{execution_id}")
          end
        end

        def save(execution_id, expected_revision:, execution:)
          Phronomy::Persistence::StorageBoundary.call do
            expected = Integer(expected_revision)
            revision = Integer(execution.execution_revision)
            raise Phronomy::Storage::ConflictError, "execution save must advance revision exactly once" unless revision == expected + 1
            unless execution.execution_id.to_s == execution_id.to_s
              raise Phronomy::Storage::SerializationError, "Execution identity mismatch"
            end
            record = Codec.encode_agent_execution(execution)
            admission do
              @view.atomic do |bound|
                entry = bound.records(StorageSchema::EXECUTIONS).replace(key: execution_id.to_s,
                  expected_revision: expected, next_revision: revision, attributes: attributes(execution),
                  expected_attributes: {}, record: record)
                decode(entry, execution_id, owner: execution.agent_id, revision: revision, active: execution.active?)
              end
            end
          end
        end

        def list_active(agent_id)
          Phronomy::Persistence::StorageBoundary.call do
            @view.atomic do |bound|
              bound.records(StorageSchema::EXECUTIONS).scan(index: :owner_active,
                equals: {owner: agent_id.to_s, active: true}).map { |entry| decode(entry, entry.key, owner: agent_id, active: true) }.freeze
            end
          end
        end

        def list(agent_id, after: nil, limit: 100)
          Phronomy::Persistence::StorageBoundary.call do
            raise ArgumentError, "limit must be a positive Integer" unless limit.is_a?(Integer) && limit.positive?
            @view.atomic do |bound|
              bound.records(StorageSchema::EXECUTIONS).scan(index: :owner, equals: {owner: agent_id.to_s},
                after: after&.to_s, limit: limit).map { |entry| decode(entry, entry.key, owner: agent_id) }.freeze
            end
          end
        end

        def delete(execution_id)
          Phronomy::Persistence::StorageBoundary.call do
            @view.records(StorageSchema::EXECUTIONS).delete(key: execution_id.to_s)
          end
        end

        def delete_for_agent(agent_id)
          Phronomy::Persistence::StorageBoundary.call do
            @view.records(StorageSchema::EXECUTIONS).delete_matching(index: :owner, equals: {owner: agent_id.to_s})
          end
        end

        def assert_idle!(agent_id)
          Phronomy::Persistence::StorageBoundary.call do
            condition = Phronomy::Storage::Condition::NoRows.new(resource: StorageSchema::EXECUTIONS,
              index: :owner_active, equals: {owner: agent_id.to_s, active: true})
            @view.check!(guards: [Phronomy::Storage::GuardRef.new(resource: StorageSchema::ROOTS, key: agent_id.to_s)],
              conditions: [condition])
          rescue Phronomy::Storage::ConditionFailedError => error
            raise unless error.condition.equal?(condition)
            raise Phronomy::AgentBusyError, error.message
          end
        end

        private

        def attributes(execution) = {owner: execution.agent_id.to_s, active: execution.active?}

        def admission
          yield
        rescue Phronomy::Storage::UniqueConstraintError => error
          raise unless error.resource == StorageSchema::EXECUTIONS.id && error.constraint == :one_active_owner
          raise Phronomy::AgentBusyError, error.message
        end

        def decode(entry, execution_id, owner: nil, revision: nil, active: nil)
          execution = Codec.decode_agent_execution(entry.record)
          valid = entry.key == execution_id.to_s && execution.execution_id == entry.key &&
            execution.execution_revision == entry.revision && attributes(execution) == entry.attributes &&
            (!owner || execution.agent_id == owner.to_s) && (!revision || execution.execution_revision == revision) &&
            (active.nil? || execution.active? == active)
          unless valid
            raise Phronomy::Storage::SerializationError, "backend returned another Agent Execution identity/metadata"
          end
          execution
        end
      end
    end
  end
end
