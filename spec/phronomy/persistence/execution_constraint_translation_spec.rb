# frozen_string_literal: true

require "spec_helper"
require "phronomy/testing/persistence_contract"

RSpec.describe "Feature-owned storage constraint translation (ADR-043; F0/F2, no X0)" do
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
      let(:raw) { Object.new }
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
            error = Phronomy::Storage::ActiveExecutionConflictError.new("stored owner is busy")
            allow(raw).to receive(operation).and_raise(error)
            expect(&invoke_operation).to raise_error(Phronomy::AgentBusyError, error.message) { |mapped|
              expect(mapped.cause).to equal(error)
            }
          end

          it "does not relabel ordinary conflicts, I/O failures or legacy lifecycle errors" do
            [Phronomy::Storage::ConflictError.new("duplicate ID or stale revision"),
              IOError.new("storage unavailable"),
              Phronomy::AgentBusyError.new("legacy backend")].each do |error|
              allow(raw).to receive(operation).and_raise(error)
              expect(&invoke_operation).to raise_error { |caught| expect(caught).to equal(error) }
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
        expect(error.cause).to be_a(Phronomy::Storage::ActiveExecutionConflictError)
      }
      expect(persistence.contents.exist?(content_id)).to be(false)
    end
  end
end
