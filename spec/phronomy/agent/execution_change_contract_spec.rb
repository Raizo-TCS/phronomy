# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::ExecutionChange do
  let(:stores) { Phronomy::PersistenceComposition.in_memory }
  let(:klass) { Class.new(Phronomy::Agent::Base) { agent_definition id: "unit4-spi", version: 1 } }
  let(:agent) { klass.create(agent_id: "spi-agent", persistence: stores.agent) }
  let(:current) do
    record = Phronomy::Agent::JournalRecord.new(agent_id: agent.agent_id, kind: :input_received, channel: :external)
    value = Phronomy::Agent::AgentExecution.start(agent_root: agent.agent_root, input_record: record, execution_id: "spi-run")
    stores.agent.executions.create_active(value)
    value
  end
  let(:change) do
    described_class.new(agent: agent, current: current, root: agent.agent_root,
      kind: :dispatch, updated: current.with(status: :active, phase: :calling_llm))
  end

  after { Phronomy.reset_runtime! }

  it "publishes one result after the outer commit and rejects reuse" do
    updated = change.perform
    expect(stores.agent.observe_execution(agent_id: agent.agent_id, execution_id: current.execution_id)).to be_active
    expect(updated.execution_revision).to eq(current.execution_revision + 1)
    expect { change.perform }.to raise_error(Phronomy::ConfigurationError, /single-use/)
  end

  it "cannot publish from a successful nested savepoint" do
    current
    expect { stores.coordinator.atomic { change.perform } }.to raise_error(Phronomy::Persistence::TransactionError)
    expect(stores.agent.executions.load(current.execution_id).to_h).to eq(current.to_h)
  end

  it "rejects another coordinator without mutation" do
    other = Phronomy::PersistenceComposition.in_memory
    current
    expect { other.coordinator.atomic { |scope| change.prepare_in(scope) } }.to raise_error(Phronomy::Persistence::TransactionError)
    expect(stores.agent.executions.load(current.execution_id).to_h).to eq(current.to_h)
  end

  it "requires preparation in the exact synchronous scope" do
    current
    expect { stores.coordinator.atomic { |scope| change.commit_in(scope) } }.to raise_error(Phronomy::ConfigurationError)
    expect(stores.agent.executions.load(current.execution_id).to_h).to eq(current.to_h)
  end

  it "rejects cross-thread participation" do
    owned = change
    stores.coordinator.atomic do |scope|
      error = Thread.new {
        begin
          owned.prepare_in(scope)
        rescue
          $!
        end
      }.value
      expect(error).to be_a(Phronomy::Persistence::TransactionError)
    end
  end

  it "rechecks a changed execution revision before saving" do
    owned = change
    stores.agent.executions.save(current.execution_id, expected_revision: current.execution_revision,
      execution: current.with(status: :active))
    expect { owned.perform }.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "distinguishes preparing from a terminal observation" do
    current
    observed = stores.agent.observe_execution(agent_id: agent.agent_id, execution_id: current.execution_id)
    expect(observed).to be_active
    expect(observed).to be_continuable
    expect(observed).not_to be_terminal
  end

  it "records cancellation without changing the captured execution revision" do
    original = current
    stores.agent.request_cancellation(agent_id: agent.agent_id, execution_id: original.execution_id)
    expect(stores.agent.executions.load(original.execution_id).execution_revision).to eq(original.execution_revision)
    expect(stores.agent.observe_execution(agent_id: agent.agent_id, execution_id: original.execution_id)).not_to be_continuable
  end

  it "rejects a participant version mismatch before any dispatch change" do
    extension = Phronomy::Agent::ExecutionExtensionState.new(binding_key: "example", binding_version: 1)
    value = current.with(metadata: {"execution_extension" => extension.to_h})
    stores.agent.executions.save(current.execution_id, expected_revision: current.execution_revision, execution: value)
    participant = double(binding: extension.with(binding_version: 2))
    expect do
      described_class.new(agent: agent, current: value, root: agent.agent_root, kind: :dispatch,
        updated: value.with(status: :active), config: {phronomy_execution_participant: participant})
    end.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    expect(stores.agent.executions.load(value.execution_id).to_h).to eq(value.to_h)
  end
end
