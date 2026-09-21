# frozen_string_literal: true

module Phronomy
  module MultiAgent
    module Persistence
      # Domain repository over a raw repository in the selected storage transaction.
      # @api private
      class TeamExecutionRepository
        def initialize(backend_repository)
          @backend_repository = backend_repository
        end

        def create_active(execution)
          unless execution.active?
            raise Phronomy::Storage::SerializationError,
              "create_active requires an active TeamExecution"
          end
          record = Codec.encode_team_execution(execution)
          stored = @backend_repository.create_active(
            team_execution_id: execution.team_execution_id.to_s,
            team_id: execution.team_id.to_s,
            execution_revision: Integer(execution.execution_revision),
            record: record
          )
          decode_for_execution(
            stored,
            execution.team_execution_id,
            team_id: execution.team_id,
            revision: execution.execution_revision,
            active: true
          )
        rescue Phronomy::Storage::ActiveExecutionConflictError => error
          raise Phronomy::AgentBusyError, error.message
        end

        def load(team_execution_id)
          decode_for_execution(@backend_repository.load(team_execution_id.to_s), team_execution_id)
        end

        def save(team_execution_id, expected_revision:, execution:)
          expected = Integer(expected_revision)
          next_revision = Integer(execution.execution_revision)
          unless next_revision == expected + 1
            raise Phronomy::Storage::ConflictError,
              "execution save must advance revision exactly once: " \
              "expected #{expected + 1}, got #{next_revision}"
          end
          unless execution.team_execution_id.to_s == team_execution_id.to_s
            raise Phronomy::Storage::SerializationError,
              "Execution identity mismatch: #{execution.team_execution_id} != #{team_execution_id}"
          end

          record = Codec.encode_team_execution(execution)
          stored = @backend_repository.save(
            team_execution_id.to_s,
            expected_revision: expected,
            next_revision: next_revision,
            team_id: execution.team_id.to_s,
            active: execution.active?,
            record: record
          )
          decode_for_execution(
            stored,
            team_execution_id,
            team_id: execution.team_id,
            revision: next_revision,
            active: execution.active?
          )
        rescue Phronomy::Storage::ActiveExecutionConflictError => error
          raise Phronomy::AgentBusyError, error.message
        end

        def list_active(team_id)
          Array(@backend_repository.list_active(team_id.to_s)).map do |record|
            decode_for_execution(record, nil, team_id: team_id, active: true)
          end.freeze
        end

        def list(team_id, after: nil, limit: 100)
          raise ArgumentError, "limit must be a positive Integer" unless limit.is_a?(Integer) && limit.positive?
          Array(@backend_repository.list(team_id.to_s, after: after&.to_s, limit: limit)).map do |record|
            decode_for_execution(record, nil, team_id: team_id)
          end.freeze
        end

        def delete(team_execution_id)
          @backend_repository.delete(team_execution_id.to_s)
        end

        def delete_for_team(team_id)
          @backend_repository.delete_for_team(team_id.to_s)
        end

        def assert_idle!(team_id)
          @backend_repository.assert_idle!(team_id.to_s)
        rescue Phronomy::Storage::ActiveExecutionConflictError => error
          raise Phronomy::AgentBusyError, error.message
        end

        private

        def decode_for_execution(record, team_execution_id, team_id: nil, revision: nil, active: nil)
          execution = Codec.decode_team_execution(record)
          if team_execution_id && execution.team_execution_id != team_execution_id.to_s
            raise Phronomy::Storage::SerializationError,
              "backend returned Execution #{execution.team_execution_id.inspect}; expected #{team_execution_id.to_s.inspect}"
          end
          if team_id && execution.team_id != team_id.to_s
            raise Phronomy::Storage::SerializationError,
              "backend returned Execution for Agent #{execution.team_id.inspect}; expected #{team_id.to_s.inspect}"
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
