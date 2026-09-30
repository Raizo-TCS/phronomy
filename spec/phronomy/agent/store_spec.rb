# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::Store do
  let(:stores) { Phronomy::PersistenceComposition.in_memory }
  let(:store) { stores.agent }
  let(:root) { Phronomy::Agent::AgentRoot.create(agent_id: "coordinator", agent_definition_id: "test", agent_definition_version: 1) }
  let(:batch) do
    [
      {"tool_invocation_id" => "first", "tool_name" => "enqueue_task", "arguments" => {"description" => "one", "metadata" => nil}, "status" => "authorized"},
      {"tool_invocation_id" => "unapproved", "tool_name" => "enqueue_task", "arguments" => {"description" => "blocked"}, "status" => "pending"},
      {"tool_invocation_id" => "other", "tool_name" => "unrelated", "arguments" => {}, "status" => "authorized"},
      {"tool_invocation_id" => "last", "tool_name" => "finalize", "arguments" => {}, "status" => "authorized"}
    ]
  end

  before do
    store.agents.create(root)
    input = Phronomy::Agent::JournalRecord.new(agent_id: root.agent_id, kind: :input_received,
      channel: :external, role: :user, content_ref: store.contents.put_text("plan"))
    execution = Phronomy::Agent::AgentExecution.start(agent_root: root, input_record: input,
      execution_id: "run", metadata: {Phronomy::Agent::ExecutionMetadata::TOOL_BATCH_METADATA_KEY => batch})
    store.executions.create_active(execution)
  end

  def project(scope, **changes)
    store.authorized_operations(scope, agent_id: "coordinator", execution_id: "run",
      invocation_id: "last", name: "finalize", arguments: {}, names: %w[enqueue_task finalize], **changes)
  end

  it "returns only authorized domain operations in Provider order even when the last operation requests them" do
    stores.coordinator.atomic do |scope|
      operations = project(scope)
      expect(operations.map(&:invocation_id)).to eq(%w[first last])
      expect(operations.first.arguments).to eq("description" => "one")
      expect(operations).to be_frozen
      expect { operations.first.arguments["description"].replace("changed") }.to raise_error(FrozenError)
      expect(operations.first.members).to eq(%i[invocation_id name arguments])
    end
  end

  [
    {agent_id: "another-owner"},
    {invocation_id: "missing"},
    {invocation_id: "unapproved", name: "enqueue_task", arguments: {"description" => "blocked"}},
    {name: "enqueue_task"},
    {arguments: {"summary" => "forged"}},
    {names: ["enqueue_task"]}
  ].each do |changes|
    it "rejects authorization mismatch #{changes.inspect} and rolls back the containing operation" do
      expect do
        stores.coordinator.atomic do |scope|
          store.participate(scope) { |records| records.agents.save(root.agent_id, expected_revision: 0, root: root.with(agent_revision: 1)) }
          project(scope, **changes)
        end
      end.to raise_error(Phronomy::Persistence::StateConflictError)
      expect(store.agents.load(root.agent_id).agent_revision).to eq(0)
    end
  end

  it "rejects another coordinator and an expired scope" do
    other = Phronomy::PersistenceComposition.in_memory.coordinator
    expect { other.atomic { |scope| project(scope) } }.to raise_error(Phronomy::Persistence::TransactionError)
    expired = nil
    stores.coordinator.atomic { |scope| expired = scope }
    expect { project(expired) }.to raise_error(Phronomy::Persistence::TransactionError)
  end

  it "reports authoritative absence and propagates failed presence reads" do
    expect(store.exist?(root.agent_id)).to be(true)
    expect(store.exist?("missing")).to be(false)
    allow(store.agents).to receive(:load).and_raise(IOError, "unavailable")
    expect { store.exist?(root.agent_id) }.to raise_error(IOError, "unavailable")
  end
end
