# frozen_string_literal: true

require "securerandom"

RSpec.shared_examples "an Execution repository" do
  let(:execution_repository) { persistence.executions }
  let(:execution_agent_root) do
    Phronomy::Agent::AgentRoot.create(
      agent_id: "execution-agent-#{SecureRandom.uuid}",
      agent_definition_id: "contract-agent",
      agent_definition_version: 1
    )
  end

  def build_contract_execution(root)
    input_record = Phronomy::Agent::JournalRecord.new(
      agent_id: root.agent_id,
      kind: :input_received,
      channel: :external,
      role: :user,
      context_candidate: false
    )
    Phronomy::Agent::AgentExecution.start(
      agent_root: root,
      input_record: input_record
    )
  end

  before do
    persistence.agents.create(execution_agent_root)
  end

  it "creates and loads an active execution" do
    execution = build_contract_execution(execution_agent_root)

    expect(execution_repository.create_active(execution).to_h).to eq(execution.to_h)
    expect(execution_repository.load(execution.execution_id).to_h).to eq(execution.to_h)
  end

  it "raises NotFoundError for a missing execution" do
    expect do
      execution_repository.load("missing-#{SecureRandom.uuid}")
    end.to raise_error(Phronomy::Persistence::NotFoundError)
  end

  it "rejects a duplicate execution_id" do
    execution = build_contract_execution(execution_agent_root)
    execution_repository.create_active(execution)

    expect do
      execution_repository.create_active(execution)
    end.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "admits at most one active or suspended execution for one Agent" do
    first = build_contract_execution(execution_agent_root)
    second = build_contract_execution(execution_agent_root)
    execution_repository.create_active(first)

    expect do
      execution_repository.create_active(second)
    end.to raise_error(Phronomy::AgentBusyError)
  end

  it "allows different Agents to have active executions" do
    other_root = Phronomy::Agent::AgentRoot.create(
      agent_id: "execution-agent-#{SecureRandom.uuid}",
      agent_definition_id: "contract-agent",
      agent_definition_version: 1
    )
    persistence.agents.create(other_root)

    expect do
      execution_repository.create_active(build_contract_execution(execution_agent_root))
      execution_repository.create_active(build_contract_execution(other_root))
    end.not_to raise_error
  end

  it "saves only at the expected execution revision" do
    execution = build_contract_execution(execution_agent_root)
    execution_repository.create_active(execution)
    updated = execution.with(status: :active, phase: :calling_llm)

    expect(
      execution_repository.save(
        execution.execution_id,
        expected_revision: 0,
        execution: updated
      ).to_h
    ).to eq(updated.to_h)
    expect(execution_repository.load(execution.execution_id).execution_revision).to eq(1)
  end

  it "rejects a stale execution revision" do
    execution = build_contract_execution(execution_agent_root)
    execution_repository.create_active(execution)
    updated = execution.with(status: :active, phase: :calling_llm)
    execution_repository.save(
      execution.execution_id,
      expected_revision: 0,
      execution: updated
    )

    expect do
      execution_repository.save(
        execution.execution_id,
        expected_revision: 0,
        execution: updated
      )
    end.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "rejects an execution identity mismatch" do
    execution = build_contract_execution(execution_agent_root)
    execution_repository.create_active(execution)
    other_root = Phronomy::Agent::AgentRoot.create(
      agent_id: "execution-agent-#{SecureRandom.uuid}",
      agent_definition_id: "contract-agent",
      agent_definition_version: 1
    )
    persistence.agents.create(other_root)
    other = build_contract_execution(other_root).with(
      execution_revision: 1,
      status: :active,
      phase: :calling_llm
    )

    expect do
      execution_repository.save(
        execution.execution_id,
        expected_revision: 0,
        execution: other
      )
    end.to raise_error(Phronomy::Persistence::SerializationError)
  end

  it "requires execution revision to advance exactly once" do
    execution = build_contract_execution(execution_agent_root)
    execution_repository.create_active(execution)
    skipped = execution.with(
      execution_revision: 2,
      status: :active,
      phase: :calling_llm
    )

    expect do
      execution_repository.save(
        execution.execution_id,
        expected_revision: 0,
        execution: skipped
      )
    end.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "lists active executions for one Agent" do
    execution = build_contract_execution(execution_agent_root)
    execution_repository.create_active(execution)

    expect(execution_repository.list_active(execution_agent_root.agent_id).map(&:execution_id))
      .to eq([execution.execution_id])
  end

  it "asserts idle state and rejects active Agents" do
    expect do
      execution_repository.assert_idle!(execution_agent_root.agent_id)
    end.not_to raise_error

    execution_repository.create_active(build_contract_execution(execution_agent_root))

    expect do
      execution_repository.assert_idle!(execution_agent_root.agent_id)
    end.to raise_error(Phronomy::AgentBusyError)
  end

  it "deletes one execution" do
    execution = build_contract_execution(execution_agent_root)
    execution_repository.create_active(execution)
    execution_repository.delete(execution.execution_id)

    expect do
      execution_repository.load(execution.execution_id)
    end.to raise_error(Phronomy::Persistence::NotFoundError)
  end

  it "deletes all executions for one Agent without deleting other Agents' executions" do
    other_root = Phronomy::Agent::AgentRoot.create(
      agent_id: "execution-agent-#{SecureRandom.uuid}",
      agent_definition_id: "contract-agent",
      agent_definition_version: 1
    )
    persistence.agents.create(other_root)
    own = build_contract_execution(execution_agent_root)
    other = build_contract_execution(other_root)
    execution_repository.create_active(own)
    execution_repository.create_active(other)

    execution_repository.delete_for_agent(execution_agent_root.agent_id)

    expect(execution_repository.list_active(execution_agent_root.agent_id)).to be_empty
    expect(execution_repository.load(other.execution_id).execution_id).to eq(other.execution_id)
  end
end
