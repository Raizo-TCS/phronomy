# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::MultiAgent::NativeDispatchEvidence do
  let(:stores) { Phronomy::PersistenceComposition.in_memory }
  let(:persistence) { stores.agent }
  let(:child_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "native-proof-child", version: 1
      model "offline-model"
    end
  end
  let(:parent_class) do
    worker = child_class
    Class.new(Phronomy::MultiAgent::Orchestrator) do
      agent_definition id: "native-proof-parent", version: 1
      model "offline-model"
      subagent :worker, worker
    end
  end
  let(:parent) do
    parent_class.create(agent_id: "native-proof-parent-owner", persistence: persistence,
      coordination_store: stores.multi_agent)
  end
  let(:participant) { parent.__invocation_config({}).fetch(:phronomy_execution_participant) }
  let(:execution) do
    input = Phronomy::Agent::JournalRecord.new(agent_id: parent.agent_id,
      execution_id: "native-proof-run", kind: :external_message, channel: :llm,
      role: :user, content_ref: persistence.contents.put_text("input"), context_candidate: true)
    Phronomy::Agent::AgentExecution.start(agent_root: parent.agent_root,
      input_record: input, execution_id: "native-proof-run").with(status: :active,
        metadata: {"execution_extension" => participant.binding.to_h})
  end

  before { persistence.transaction { |records| records.executions.create_active(execution) } }

  def change_for(current = execution, imported: false)
    metadata = current.metadata.dup
    if imported
      metadata.delete(Phronomy::Agent::ExecutionMetadata::TOOL_BATCH_METADATA_KEY)
    else
      metadata[Phronomy::Agent::ExecutionMetadata::TOOL_BATCH_METADATA_KEY] = [
        {"tool_invocation_id" => "native-proof-slot", "tool_name" => "dispatch_to_worker",
         "arguments" => {"input" => "child input"}, "status" => "authorized"}
      ]
    end
    updated = current.with(phase: imported ? :calling_llm : :dispatching_tools, metadata: metadata)
    Phronomy::Agent::ExecutionChange.new(agent: parent, current: current, root: parent.agent_root,
      kind: :dispatch, updated: updated, config: {phronomy_execution_participant: participant})
  end

  def capture(change, rollback: false)
    if rollback
      armed = true
      allow(persistence.coordinator).to receive(:atomic).and_wrap_original do |original, &body|
        if armed
          armed = false
          original.call do |scope|
            body.call(scope)
            raise IOError, "native dispatch rollback"
          end
        else
          original.call(&body)
        end
      end
      expect { change.perform }.to raise_error(IOError, "native dispatch rollback")
      allow(persistence.coordinator).to receive(:atomic).and_call_original
    else
      change.perform
    end
    Phronomy::Agent::DispatchPersistenceEvidence.capture(change, persistence: persistence,
      kind: :tool, participant: participant)
  end

  def slot(proof)
    proof.after.fetch(0).fetch(3).fetch("children").fetch(0)
  end

  def create_child(entry, terminal: true)
    hold = child_hold(entry)
    child = child_class.create(agent_id: entry.fetch("agent_id"), persistence: persistence, retention: hold)
    input = Phronomy::Agent::JournalRecord.new(agent_id: child.agent_id,
      execution_id: entry.fetch("execution_id"), kind: :external_message, channel: :llm,
      role: :user, content_ref: persistence.contents.put_text("child input"), context_candidate: true)
    active = Phronomy::Agent::AgentExecution.start(agent_root: child.agent_root,
      input_record: input, execution_id: entry.fetch("execution_id")).with(status: :active,
        metadata: {"reservation" => {"kind" => "subagent", "parent_agent_id" => parent.agent_id,
                                     "parent_execution_id" => execution.execution_id, "slot" => entry.fetch("slot")}})
    persistence.transaction do |records|
      records.executions.create_active(active)
      if terminal
        records.executions.save(active.execution_id, expected_revision: active.execution_revision,
          execution: active.with(status: :completed, phase: :completed))
      end
    end
    child
  end

  def child_hold(entry)
    Phronomy::Agent::Retention.new(agent_id: entry.fetch("agent_id"), execution_id: entry.fetch("execution_id"),
      owner_key: "subagent:#{execution.execution_id}")
  end

  def imported_proof(rollback: false)
    dispatch = capture(change_for)
    create_child(slot(dispatch))
    capture(change_for(dispatch.execution, imported: true), rollback: rollback)
  end

  it "restores the captured extension blob and parent hold after rollback without participant replay" do
    proof = capture(change_for, rollback: true)
    reference = proof.execution.metadata.fetch("execution_extension").fetch("state_ref")
    expect(proof.participation?).to be(true)
    expect(stores.multi_agent.contents.exist?(reference)).to be(false)
    expect(persistence.retained_references(agent_id: parent.agent_id)).to be_empty
    reconciled = proof.reconcile(persistence: persistence)
    expect(reconciled.disposition).to eq(:not_committed), reconciled.read_error&.full_message
    expect(participant).not_to receive(:commit)
    expect_any_instance_of(Phronomy::Agent::RuntimeRecordEncoder).not_to receive(:encode)
    result = proof.retry(persistence: persistence)
    expect(result.disposition).to eq(:committed)
    expect(result.continuation_error).to be_nil
    expect(stores.multi_agent.contents.fetch_json(reference)).to eq(proof.after.fetch(0).fetch(3))
    expect(persistence.retained_references(agent_id: parent.agent_id).map(&:to_h)).to eq(proof.after.fetch(1))
    expect(proof.retry(persistence: persistence).disposition).to eq(:committed)
  end

  it "acquires the parent and existing child guards in lexical order" do
    proof = imported_proof(rollback: true)
    expected = [parent.agent_id, slot(proof).fetch("agent_id")].sort
    expect(persistence).to receive(:guard_agents).with(anything, agent_ids: expected).and_call_original
    expect(proof.retry(persistence: persistence).disposition).to eq(:committed)
  end

  it "does not retry when a newly reserved child's root or execution has appeared" do
    proof = capture(change_for, rollback: true)
    create_child(slot(proof))
    expect(persistence.executions).not_to receive(:save)
    result = proof.retry(persistence: persistence)
    expect(result.disposition).to eq(:not_committed)
    expect(result.read_error).to be_a(Phronomy::Persistence::StateConflictError)
    expect(persistence.executions.load(execution.execution_id).to_h).to eq(execution.to_h)
    expect(persistence.retained_references(agent_id: parent.agent_id)).to be_empty
  end

  it "preserves committed parent history while a newly appeared child blocks fresh continuation" do
    proof = capture(change_for)
    create_child(slot(proof))
    expect(persistence.executions).not_to receive(:save)
    result = proof.retry(persistence: persistence)
    expect(result.disposition).to eq(:committed)
    expect(result.continuation_error).to be_a(Phronomy::Persistence::StateConflictError)
    expect(result.read_error).to be_nil
  end

  it "retries a captured import using the exact terminal child reservation and native hold" do
    proof = imported_proof(rollback: true)
    expect(slot(proof).fetch("imported")).to be(true)
    expect(participant).not_to receive(:commit)
    result = proof.retry(persistence: persistence)
    expect(result.disposition).to eq(:committed)
    expect(result.continuation_error).to be_nil
  end

  it "does not freeze terminal child root revisions or unrelated history holds" do
    proof = imported_proof
    child = slot(proof)
    other = Phronomy::Agent::Retention.new(agent_id: child.fetch("agent_id"), owner_key: "audit-observer")
    persistence.retain(other)
    persistence.transaction do |records|
      root = records.agents.load(child.fetch("agent_id"))
      records.agents.save(root.agent_id, expected_revision: root.agent_revision,
        root: root.with(agent_revision: root.agent_revision + 1, metadata: {"audit" => true}))
    end
    result = proof.reconcile(persistence: persistence)
    expect(result.disposition).to eq(:committed)
    expect(result.continuation_error).to be_nil
  end

  it "preserves committed import history when its required child hold is missing" do
    proof = imported_proof
    child = slot(proof)
    persistence.coordinator.atomic do |scope|
      persistence.release_retention(agent_id: child.fetch("agent_id"),
        owner_key: child_hold(child).owner_key, scope: scope)
    end
    result = proof.reconcile(persistence: persistence)
    expect(result.disposition).to eq(:committed)
    expect(result.continuation_error).to be_a(Phronomy::Persistence::StateConflictError)
  end

  it "does not retry a captured import after its terminal child correlation changes" do
    proof = imported_proof(rollback: true)
    child = slot(proof)
    persistence.transaction do |records|
      current = records.executions.load(child.fetch("execution_id"))
      records.executions.save(current.execution_id, expected_revision: current.execution_revision,
        execution: current.with(metadata: current.metadata.merge("reservation" => {"owner" => "another"})))
    end
    result = proof.retry(persistence: persistence)
    expect(result.disposition).to eq(:not_committed)
    expect(result.read_error).to be_a(Phronomy::Persistence::StateConflictError)
    expect(persistence.executions.load(execution.execution_id).to_h).to eq(proof.before.fetch(0).fetch(1))
  end

  it "does not retry after the parent's exact retention footprint changes" do
    proof = capture(change_for, rollback: true)
    persistence.retain(Phronomy::Agent::Retention.new(agent_id: parent.agent_id, owner_key: "another-owner"))
    result = proof.retry(persistence: persistence)
    expect(result.disposition).to eq(:unknown)
    expect(persistence.executions.load(execution.execution_id).to_h).to eq(execution.to_h)
  end

  it "rejects a native factory from a different Agent Store" do
    change = change_for
    change.perform
    other = Phronomy::Agent::Store.new(coordinator: persistence.coordinator, records: Phronomy::Agent::Persistence::Records)
    expect {
      described_class.capture(values: change.captured_evidence, persistence: other,
        native_persistence: stores.multi_agent)
    }.to raise_error(Phronomy::Persistence::StateConflictError, /another Store/)
  end

  it "rejects a captured extension whose canonical bytes do not match its reference" do
    change = change_for
    change.perform
    values = Marshal.load(Marshal.dump(change.captured_evidence.except(:result)))
    values[:result] = change.captured_evidence.fetch(:result)
    values[:after][0][3]["cancel_requested"] = true
    expect {
      described_class.capture(values: values, persistence: persistence, native_persistence: stores.multi_agent)
    }.to raise_error(Phronomy::Persistence::StateConflictError, /captured reference/)
  end
end
