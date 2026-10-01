# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::MultiAgent::ReservedChildAdmission do
  let(:stores) { Phronomy::PersistenceComposition.in_memory }
  let(:store) { stores.agent }
  let(:multi_agent_store) { stores.multi_agent }
  let(:root) { Phronomy::Agent::AgentRoot.create(agent_id: "child", agent_definition_id: "child", agent_definition_version: 1) }
  let(:owner) { {"kind" => "team", "team_id" => "parent", "team_execution_id" => "run", "slot" => "coordinator"} }
  let(:reservation) { described_class.new(persistence: multi_agent_store, owner: owner) }
  let(:admission) do
    Phronomy::Agent::Admission.new(persistence: store, root: root, input: "input",
      config: {phronomy_reserved_execution_id: "child-run", phronomy_reservation: owner}, preparation_metadata: {})
  end
  let(:team) do
    now = Time.now.utc.iso8601(6)
    Phronomy::MultiAgent::TeamRoot.new(team_id: "parent", team_definition_id: "test",
      team_definition_version: 1, team_revision: 0, lifecycle_status: "active",
      created_at: now, updated_at: now, metadata: {})
  end
  let(:run) do
    now = Time.now.utc.iso8601(6)
    Phronomy::MultiAgent::TeamExecution.new(team_execution_id: "run", team_id: "parent",
      execution_revision: 0, status: "active", phase: "coordinator", input_ref: nil,
      coordinator: {"agent_id" => "child", "execution_id" => "child-run"}, tasks: [], workers: [],
      assignments: [], result_ref: nil, error_ref: nil, created_at: now, updated_at: now, metadata: {})
  end

  before do
    store.agents.create(root)
    multi_agent_store.teams.create(team)
    multi_agent_store.team_executions.create_active(run)
  end

  it "locks the parent before reading its reservation and committing Agent admission" do
    calls = []
    allow(store.coordinator.backend).to receive(:lock_guard).and_wrap_original do |method, context, resource, **args|
      calls << [:lock, resource.id]
      method.call(context, resource, **args)
    end
    allow(store.coordinator.backend).to receive(:read_record).and_wrap_original do |method, context, resource, **args|
      calls << [:read, resource.id]
      method.call(context, resource, **args)
    end
    reservation.admit(admission)
    execution, updated_root = admission.result
    expect(calls.index([:lock, "team.roots"])).to be < calls.index([:read, "team.executions"])
    expect(execution.execution_id).to eq("child-run")
    expect(updated_root.lifecycle_status).to eq(:active)
    expect(store.executions.load("child-run").metadata.fetch("reservation")).to eq(owner)
    expect(store.agents.load("child").agent_revision).to eq(1)
    expect(root.lifecycle_status).to eq(:idle)
  end

  it "does not admit a child after a committed parent cancellation" do
    multi_agent_store.team_executions.save("run", expected_revision: 0, execution: run.with(metadata: {"cancel_requested" => true}))
    expect { reservation.admit(admission) }.to raise_error(Phronomy::CancellationError)
    expect(store.executions.list("child")).to be_empty
    expect(store.agents.load("child").agent_revision).to eq(0)
  end

  it "rejects a changed child identity without persisting input or execution" do
    multi_agent_store.team_executions.save("run", expected_revision: 0,
      execution: run.with(coordinator: {"agent_id" => "child", "execution_id" => "other-run"}))
    expect { reservation.admit(admission) }.to raise_error(Phronomy::Persistence::StateConflictError)
    expect(store.executions.list("child")).to be_empty
  end

  it "rolls the entire admission back on a stale Agent root" do
    store.agents.save("child", expected_revision: 0, root: root.with(agent_revision: 1))
    expect { reservation.admit(admission) }.to raise_error(Phronomy::Persistence::ConflictError)
    expect(store.executions.list("child")).to be_empty
    expect { admission.result }.to raise_error(Phronomy::Persistence::TransactionError)
  end

  it "cannot expose a result inside an enclosing transaction or after its rollback" do
    expect do
      store.coordinator.atomic do
        reservation.admit(admission)
        admission.result
      end
    end.to raise_error(Phronomy::Persistence::TransactionError, /not committed/)
    expect(store.executions.list("child")).to be_empty
  end

  it "rejects another Persistence participant and a second use of a request" do
    other = Phronomy::PersistenceComposition.in_memory.agent
    expect { other.coordinator.atomic { |scope| admission.accept_in(scope) } }
      .to raise_error(Phronomy::Persistence::TransactionError)
    expect { admission.accept }.to raise_error(Phronomy::ConfigurationError, /single-use/)
  end

  it "fails closed when a coordinated invocation lacks its live reservation owner" do
    fake_agent = Struct.new(:agent_id).new("child")
    prepare = Phronomy::Agent::InitialPreparation.new(agent: fake_agent, persistence: store)
    expect do
      prepare.send(:admit_execution, "input", root: root, config: {phronomy_reservation: owner})
    end.to raise_error(Phronomy::ConfigurationError, /current owner/)
    expect(store.executions.list("child")).to be_empty
  end
end
