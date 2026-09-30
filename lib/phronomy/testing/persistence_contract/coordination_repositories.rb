# frozen_string_literal: true

require "securerandom"
require "time"

RSpec.shared_context "coordination repository values" do
  let(:coordination_team) do
    now = Time.now.utc.iso8601(6)
    Phronomy::MultiAgent::TeamRoot.new(team_id: SecureRandom.uuid,
      team_definition_id: "contract-team", team_definition_version: 1,
      team_revision: 0, lifecycle_status: "idle", created_at: now, updated_at: now, metadata: {})
  end
  let(:coordination_run) do
    now = Time.now.utc.iso8601(6)
    Phronomy::MultiAgent::TeamExecution.new(team_execution_id: SecureRandom.uuid,
      team_id: coordination_team.team_id, execution_revision: 0, status: "active", phase: "coordinator",
      input_ref: nil, coordinator: {}, tasks: [], workers: [], assignments: [], result_ref: nil,
      error_ref: nil, created_at: now, updated_at: now, metadata: {})
  end
  let(:coordination_handoff) do
    now = Time.now.utc.iso8601(6)
    Phronomy::Agent::HandoffState.new(main_agent_id: SecureRandom.uuid, handoff_revision: 1,
      active_agent_id: "contract-target", active_handoff_context_ref: nil, phase: "target_pending",
      pending_source_execution_id: "source-execution", pending_target_execution_id: "target-execution",
      created_at: now, updated_at: now, metadata: {})
  end
end

RSpec.shared_examples "a Handoff state repository" do
  include_context "coordination repository values"

  it "returns nil only for an authoritative absent Handoff anchor" do
    expect(stores.agent.handoff_states.load(SecureRandom.uuid)).to be_nil
  end

  it "round-trips the immutable Handoff snapshot and rejects stale routing CAS" do
    value = coordination_handoff
    stores.agent.handoff_states.save(value.main_agent_id, expected_revision: nil, state: value)
    loaded = stores.agent.handoff_states.load(value.main_agent_id)
    expect(loaded.to_h).to eq(value.to_h)
    expect(loaded).to be_frozen
    updated = value.with(phase: "stable")
    stores.agent.handoff_states.save(value.main_agent_id, expected_revision: 1, state: updated)
    expect do
      stores.agent.handoff_states.save(value.main_agent_id, expected_revision: 1, state: updated)
    end.to raise_error(Phronomy::Persistence::ConflictError)
    expect(stores.agent.handoff_states.load(value.main_agent_id).handoff_revision).to eq(2)
  end

  it "rejects a snapshot for a different routing anchor" do
    expect do
      stores.agent.handoff_states.save("other", expected_revision: nil, state: coordination_handoff)
    end.to raise_error(Phronomy::Persistence::SerializationError)
  end
end

RSpec.shared_examples "a Team repository" do
  include_context "coordination repository values"

  it "round-trips a Team lineage and rejects duplicate creation" do
    stores.team.teams.create(coordination_team)
    expect(stores.team.teams.load(coordination_team.team_id).to_h).to eq(coordination_team.to_h)
    expect { stores.team.teams.create(coordination_team) }.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "rejects a stale Team revision" do
    stores.team.teams.create(coordination_team)
    updated = coordination_team.with(lifecycle_status: "active")
    stores.team.teams.save(coordination_team.team_id, expected_revision: 0, root: updated)
    expect do
      stores.team.teams.save(coordination_team.team_id, expected_revision: 0, root: updated)
    end.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "raises NotFoundError for an absent Team" do
    expect { stores.team.teams.load(SecureRandom.uuid) }.to raise_error(Phronomy::Persistence::NotFoundError)
  end
end

RSpec.shared_examples "a Team execution repository" do
  include_context "coordination repository values"
  before { stores.team.teams.create(coordination_team) }

  it "atomically admits at most one active run per Team" do
    stores.team.team_executions.create_active(coordination_run)
    other = coordination_run.with(team_execution_id: SecureRandom.uuid, execution_revision: 0)
    expect { stores.team.team_executions.create_active(other) }.to raise_error(Phronomy::AgentBusyError)
    expect(stores.team.team_executions.list_active(coordination_team.team_id).map(&:team_execution_id)).to eq([coordination_run.team_execution_id])
  end

  it "releases admission after terminal CAS while retaining discoverable outcomes" do
    stores.team.team_executions.create_active(coordination_run)
    completed = coordination_run.with(status: "completed", phase: "completed")
    stores.team.team_executions.save(coordination_run.team_execution_id, expected_revision: 0, execution: completed)
    other = coordination_run.with(team_execution_id: SecureRandom.uuid, execution_revision: 0)
    stores.team.team_executions.create_active(other)
    ids = [completed.team_execution_id, other.team_execution_id].sort
    expect(stores.team.team_executions.list(coordination_team.team_id, limit: 1).map(&:team_execution_id)).to eq(ids.first(1))
    expect(stores.team.team_executions.list(coordination_team.team_id, after: ids.first).map(&:team_execution_id)).to eq(ids.last(1))
    expect(stores.team.team_executions.list("other-team")).to be_empty
    expect do
      stores.team.team_executions.save(completed.team_execution_id, expected_revision: 0, execution: completed)
    end.to raise_error(Phronomy::Persistence::ConflictError)
    expect do
      stores.team.team_executions.save(completed.team_execution_id, expected_revision: 1,
        execution: completed.with(status: "active", phase: "coordinator"))
    end.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "rolls the new three repositories back with the existing transaction domain" do
    handoff = coordination_handoff
    root_id = "coordination-rollback-agent-#{SecureRandom.uuid}"
    content_ref = nil
    expect do
      stores.coordinator.atomic do |scope|
        stores.team.participate(scope) do |team|
          stores.agent.participate(scope) do |agent|
            scope.participate(persistence: stores.coordinator, adapter: Phronomy::Workflow::Persistence::StateRepository) do |workflow|
              team.team_executions.create_active(coordination_run)
              team.teams.save(coordination_team.team_id, expected_revision: 0, root: coordination_team.with(lifecycle_status: "active"))
              agent.handoff_states.save(handoff.main_agent_id, expected_revision: nil, state: handoff)
              content_ref = agent.contents.put_text("coordination-rollback-#{SecureRandom.uuid}")
              root = Phronomy::Agent::AgentRoot.create(agent_id: root_id, agent_definition_id: "rollback", agent_definition_version: 1)
              agent.agents.create(root)
              agent.journals.append(root_id, expected_position: 0, records: [])
              record = Phronomy::Agent::JournalRecord.new(agent_id: root_id, kind: :input_received, channel: :external)
              agent.executions.create_active(Phronomy::Agent::AgentExecution.start(agent_root: root, input_record: record))
              workflow.save(root_id, expected_revision: nil, snapshot: {fields: {value: "committed"}, phase: "pause"})
              raise "rollback all eight"
            end
          end
        end
      end
    end.to raise_error(RuntimeError, "rollback all eight")
    expect(stores.team.teams.load(coordination_team.team_id).team_revision).to eq(0)
    expect(stores.agent.handoff_states.load(handoff.main_agent_id)).to be_nil
    expect(stores.team.team_executions.list(coordination_team.team_id)).to be_empty
    expect { stores.agent.agents.load(root_id) }.to raise_error(Phronomy::Persistence::NotFoundError)
    expect(stores.agent.executions.list(root_id)).to be_empty
    expect(stores.workflow.load(root_id)).to be_nil
    expect(stores.agent.contents.exist?(content_ref)).to be(false)
  end
end
