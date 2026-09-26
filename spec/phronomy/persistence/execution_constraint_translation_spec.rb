# frozen_string_literal: true

require "spec_helper"
require "phronomy/testing/persistence_contract"

RSpec.describe "Feature-owned storage constraint translation (ADR-058; F0/F2, no X0)" do
  include_context "coordination repository values"

  let(:agent_execution) do
    root = Phronomy::Agent::AgentRoot.create(agent_id: "constraint-agent",
      agent_definition_id: "constraint-test", agent_definition_version: 1)
    input = Phronomy::Agent::JournalRecord.new(agent_id: root.agent_id,
      kind: :input_received, channel: :external, role: :user, context_candidate: false)
    Phronomy::Agent::AgentExecution.start(agent_root: root, input_record: input)
  end

  [
    [Phronomy::Agent::Persistence::ExecutionRepository, :agent_execution, :execution_id, :agent_id],
    [Phronomy::MultiAgent::Persistence::TeamExecutionRepository, :coordination_run, :team_execution_id, :team_id]
  ].each do |repository_class, fixture, execution_id, owner_id|
    context repository_class.name do
      let(:value) { public_send(fixture) }
      let(:raw) do
        Object.new.tap do |view|
          def view.atomic = yield self
          def view.records(*) = self
        end
      end
      let(:resource) do
        (fixture == :agent_execution) ? Phronomy::Agent::Persistence::StorageSchema::EXECUTIONS : Phronomy::TeamStorageSchema::EXECUTIONS
      end
      let(:repository) { repository_class.new(raw) }

      [:create_active, :save, :assert_idle!].each do |operation|
        context operation.to_s do
          let(:invoke_operation) do
            case operation
            when :create_active then -> { repository.create_active(value) }
            when :save
              -> {
                repository.save(value.public_send(execution_id), expected_revision: 0,
                  execution: value.with(execution_revision: 1))
              }
            when :assert_idle! then -> { repository.assert_idle!(value.public_send(owner_id)) }
            end
          end

          it "preserves the public lifecycle error, original message and storage cause" do
            error = nil
            if operation == :assert_idle!
              allow(raw).to receive(:check!) do |guards:, conditions:|
                error = Phronomy::Storage::ConditionFailedError.new(conditions.first)
                raise error
              end
            else
              error = Phronomy::Storage::UniqueConstraintError.new(resource: resource, constraint: :one_active_owner)
              allow(raw).to receive((operation == :create_active) ? :insert : :replace).and_raise(error)
            end
            expect(&invoke_operation).to raise_error(Phronomy::AgentBusyError) { |mapped|
              expect(mapped.cause).to equal(error)
            }
          end

          it "maps ordinary conflicts without confusing them with admission and preserves unknown failures" do
            [Phronomy::Storage::ConflictError.new("duplicate ID or stale revision"),
              IOError.new("storage unavailable"),
              Phronomy::AgentBusyError.new("legacy backend")].each do |error|
              allow(raw).to receive({create_active: :insert, save: :replace, assert_idle!: :check!}.fetch(operation)).and_raise(error)
              expect(&invoke_operation).to raise_error do |caught|
                if error.is_a?(Phronomy::Storage::ConflictError)
                  expect(caught).to be_a(Phronomy::Persistence::ConflictError)
                  expect(caught).not_to be_a(Phronomy::AgentBusyError)
                  expect(caught.cause).to equal(error)
                else
                  expect(caught).to equal(error)
                end
              end
            end
          end
        end
      end
    end
  end

  [:executions, :team_executions].each do |kind|
    it "rolls back the transaction when #{kind} maps a raw constraint" do
      persistence = Phronomy::Persistence.in_memory
      if kind == :executions
        execution = agent_execution
        root = Phronomy::Agent::AgentRoot.create(agent_id: execution.agent_id,
          agent_definition_id: "constraint-test", agent_definition_version: 1)
        persistence.agents.create(root)
        other = execution.with(execution_id: "competing")
      else
        execution = coordination_run
        persistence.teams.create(coordination_team)
        other = execution.with(team_execution_id: "competing")
      end
      persistence.public_send(kind).create_active(execution)
      content_id = nil
      expect do
        persistence.transaction do |tx|
          content_id = tx.contents.put_text("must roll back with mapped error")
          tx.public_send(kind).create_active(other)
        end
      end.to raise_error(Phronomy::AgentBusyError) { |error|
        expect(error.cause).to be_a(Phronomy::Storage::UniqueConstraintError)
      }
      expect(persistence.contents.exist?(content_id)).to be(false)
    end
  end
end
