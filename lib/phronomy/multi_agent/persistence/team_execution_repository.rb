# frozen_string_literal: true

module Phronomy
  module MultiAgent
    module Persistence
      # Owns execution activity, ownership, admission and durable record encoding.
      # @api private
      class TeamExecutionRepository
        def initialize(view) = @view = view

        def create_active(execution)
          Phronomy::Persistence::StorageBoundary.call do
            raise Phronomy::Storage::SerializationError, "create_active requires an active TeamExecution" unless execution.active?
            record = Codec.encode_team_execution(execution)
            admission do
              @view.atomic do |bound|
                entry = bound.records(Phronomy::TeamStorageSchema::EXECUTIONS).insert(key: execution.team_execution_id.to_s,
                  revision: Integer(execution.execution_revision), attributes: attributes(execution), record: record)
                decode(entry, execution.team_execution_id, owner: execution.team_id,
                  revision: execution.execution_revision, active: true)
              end
            end
          end
        end

        def load(team_execution_id)
          Phronomy::Persistence::StorageBoundary.call do
            value = @view.atomic do |bound|
              entry = bound.records(Phronomy::TeamStorageSchema::EXECUTIONS).read(team_execution_id.to_s)
              entry && decode(entry, team_execution_id)
            end
            value || raise(Phronomy::Storage::NotFoundError, "TeamExecution not found: #{team_execution_id}")
          end
        end

        def save(team_execution_id, expected_revision:, execution:)
          Phronomy::Persistence::StorageBoundary.call do
            expected = Integer(expected_revision)
            revision = Integer(execution.execution_revision)
            raise Phronomy::Storage::ConflictError, "execution save must advance revision exactly once" unless revision == expected + 1
            unless execution.team_execution_id.to_s == team_execution_id.to_s
              raise Phronomy::Storage::SerializationError, "Execution identity mismatch"
            end
            record = Codec.encode_team_execution(execution)
            admission do
              @view.atomic do |bound|
                entry = bound.records(Phronomy::TeamStorageSchema::EXECUTIONS).replace(key: team_execution_id.to_s,
                  expected_revision: expected, next_revision: revision, attributes: attributes(execution),
                  expected_attributes: execution.active? ? {active: true} : {}, record: record)
                decode(entry, team_execution_id, owner: execution.team_id, revision: revision, active: execution.active?)
              end
            end
          end
        end

        def list_active(team_id)
          Phronomy::Persistence::StorageBoundary.call do
            @view.atomic do |bound|
              bound.records(Phronomy::TeamStorageSchema::EXECUTIONS).scan(index: :owner_active,
                equals: {owner: team_id.to_s, active: true}).map { |entry| decode(entry, entry.key, owner: team_id, active: true) }.freeze
            end
          end
        end

        def list(team_id, after: nil, limit: 100)
          Phronomy::Persistence::StorageBoundary.call do
            raise ArgumentError, "limit must be a positive Integer" unless limit.is_a?(Integer) && limit.positive?
            @view.atomic do |bound|
              bound.records(Phronomy::TeamStorageSchema::EXECUTIONS).scan(index: :owner, equals: {owner: team_id.to_s},
                after: after&.to_s, limit: limit).map { |entry| decode(entry, entry.key, owner: team_id) }.freeze
            end
          end
        end

        def delete(team_execution_id)
          Phronomy::Persistence::StorageBoundary.call do
            @view.records(Phronomy::TeamStorageSchema::EXECUTIONS).delete(key: team_execution_id.to_s)
          end
        end

        def delete_for_team(team_id)
          Phronomy::Persistence::StorageBoundary.call do
            @view.records(Phronomy::TeamStorageSchema::EXECUTIONS).delete_matching(index: :owner, equals: {owner: team_id.to_s})
          end
        end

        def assert_idle!(team_id)
          Phronomy::Persistence::StorageBoundary.call do
            condition = Phronomy::Storage::Condition::NoRows.new(resource: Phronomy::TeamStorageSchema::EXECUTIONS,
              index: :owner_active, equals: {owner: team_id.to_s, active: true})
            @view.check!(guards: [Phronomy::Storage::GuardRef.new(resource: Phronomy::TeamStorageSchema::ROOTS, key: team_id.to_s)],
              conditions: [condition])
          rescue Phronomy::Storage::ConditionFailedError => error
            raise unless error.condition.equal?(condition)
            raise Phronomy::AgentBusyError, error.message
          end
        end

        private

        def attributes(execution) = {owner: execution.team_id.to_s, active: execution.active?}

        def admission
          yield
        rescue Phronomy::Storage::UniqueConstraintError => error
          raise unless error.resource == Phronomy::TeamStorageSchema::EXECUTIONS.id && error.constraint == :one_active_owner
          raise Phronomy::AgentBusyError, error.message
        end

        def decode(entry, team_execution_id, owner: nil, revision: nil, active: nil)
          execution = Codec.decode_team_execution(entry.record)
          valid = entry.key == team_execution_id.to_s && execution.team_execution_id == entry.key &&
            execution.execution_revision == entry.revision && attributes(execution) == entry.attributes &&
            (!owner || execution.team_id == owner.to_s) && (!revision || execution.execution_revision == revision) &&
            (active.nil? || execution.active? == active)
          unless valid
            raise Phronomy::Storage::SerializationError, "backend returned another Team Execution identity/metadata"
          end
          execution
        end
      end
    end
  end
end
