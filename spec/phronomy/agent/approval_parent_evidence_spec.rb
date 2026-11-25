# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::ApprovalParentEvidence do
  let(:persistence) { Phronomy::PersistenceComposition.in_memory.agent }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "hosted-approval-proof", version: 1
    end
  end
  let(:parent) { agent_class.create(agent_id: "parent-proof", persistence: persistence) }
  let(:child) { agent_class.create(agent_id: "child-proof", persistence: persistence) }
  let(:parent_state) { {"slots" => [{"child" => child.agent_id, "accepted" => false}], "opaque" => "domain-owned"} }
  let(:parent_execution) do
    start_execution(parent, "parent-execution").with(status: :active, phase: :dispatching_tools,
      metadata: {"execution_extension" => {
        "binding_key" => "test.opaque-parent", "binding_version" => 1,
        "state_ref" => persistence.contents.put_json(parent_state)
      }})
  end
  let(:approval_request) do
    item = Phronomy::Agent::ToolApprovalRequest::Item.new(
      tool_invocation_id: "tool-1", tool_call_id: "call-1", tool_name: "lookup",
      arguments: {"query" => "input"}, facts: {}, reason: "approval required", origin: :local, metadata: {}
    )
    Phronomy::Agent::RecoverySupport.canonical_copy(
      Phronomy::Agent::ToolApprovalRequest.new(execution_id: "child-execution", items: [item],
        id: "child-approval", created_at: Time.utc(2026, 11, 26)).to_h
    )
  end
  let(:child_execution) do
    start_execution(child, "child-execution").with(status: :active).with(status: :suspended, phase: :approval,
      approval_request: approval_request,
      metadata: {"reservation" => {"owner" => parent.agent_id, "slot" => "original-slot"}})
  end
  let(:wait) do
    Phronomy::Agent::ApprovalWait.new(execution_id: child_execution.execution_id,
      approval_request_id: "child-approval", execution_revision: child_execution.execution_revision)
  end
  let(:parent_hold) do
    Phronomy::Agent::Retention.new(agent_id: parent.agent_id,
      execution_id: parent_execution.execution_id, owner_key: "opaque-parent-owner")
  end
  let(:child_hold) do
    Phronomy::Agent::Retention.new(agent_id: child.agent_id,
      execution_id: child_execution.execution_id, owner_key: "opaque-child-owner")
  end
  let(:command) do
    Phronomy::Agent::ApprovalResumeCommit::Command.new(execution_id: child_execution.execution_id,
      expected_execution_revision: child_execution.execution_revision,
      root: child.agent_root, execution: child_execution, approval_request_id: wait.approval_request_id,
      approved: true, tool_batch_snapshot: nil)
  end

  def start_execution(agent, id)
    input = Phronomy::Agent::JournalRecord.new(agent_id: agent.agent_id, execution_id: id,
      kind: :user_message, channel: :llm, role: :user, content_ref: persistence.contents.put_text("input"),
      context_generation: agent.agent_root.transcript_generation, context_candidate: true)
    Phronomy::Agent::AgentExecution.start(agent_root: agent.agent_root, input_record: input, execution_id: id)
  end

  def capture(**changes, &relation)
    described_class.capture(persistence: persistence, parent_agent_id: parent.agent_id,
      parent_execution_id: parent_execution.execution_id, parent_revision: parent_execution.execution_revision,
      child_agent_id: child.agent_id, **changes, &relation || -> { wait })
  end

  def retain(authority, operation = command)
    Phronomy::Agent::ApprovalResumeCommit.new(agent_id: child.agent_id, persistence: persistence)
      .commit_retained(operation, parent_evidence: authority,
        on_evidence: ->(proof) { @proof = proof }, on_outcome: ->(outcome) { @outcome = outcome })
  end

  def change_parent_execution(**changes)
    persistence.transaction do |records|
      records.executions.save(parent_execution.execution_id,
        expected_revision: parent_execution.execution_revision, execution: parent_execution.with(**changes))
    end
  end

  before do
    persistence.transaction do |records|
      records.executions.create_active(parent_execution)
      records.executions.create_active(child_execution)
      records.retentions.retain(parent_hold)
      records.retentions.retain(child_hold)
    end
  end

  it "captures the relation under both ordered Agent guards and stores detached parent facts" do
    order = []
    allow(persistence).to receive(:guard_agents).and_wrap_original do |original, scope, **options|
      order << options.fetch(:agent_ids).sort
      original.call(scope, **options)
    end
    authority = capture do
      order << :relation
      wait
    end
    expect(order).to eq([[child.agent_id, parent.agent_id].sort, :relation])
    expect(authority.snapshot.fetch(:agent).fetch(3)).to eq(parent_state)
    expect(authority.snapshot.fetch(:retentions)).to eq([parent_hold])
    expect(authority.child_snapshot.fetch(:retentions)).to eq([child_hold])
    expect(authority.child_snapshot.fetch(:agent).fetch(1)).to eq(child_execution.to_h)
    expect(authority.snapshot.fetch(:agent).fetch(4)).to be(false)
    expect(authority.wait).to eq(wait)
    expect(authority.wait.execution_id).to be_frozen
    expect(authority.wait.approval_request_id).to be_frozen
    expect(authority).to be_frozen
    expect(authority.snapshot.fetch(:agent).fetch(3)).to be_frozen
    parent_state["slots"].clear
    expect(authority.snapshot.fetch(:agent).fetch(3).fetch("slots").length).to eq(1)
  end

  it "keeps parent evidence unchanged around the child decision and never reruns the relation reader" do
    calls = 0
    authority = capture {
      calls += 1
      wait
    }
    retain(authority)
    expect(@proof.before.fetch(:parent)).to eq(authority.snapshot)
    expect(@proof.after.fetch(:parent)).to eq(authority.snapshot)
    expect(@proof.after.fetch(:retentions)).to eq([child_hold])
    2.times { expect(@proof.reconcile(persistence: persistence).disposition).to eq(:committed) }
    expect(calls).to eq(1)
  end

  it "proves rollback only while the captured parent authority still matches" do
    authority = capture
    allow(persistence).to receive(:transaction).and_wrap_original do |original, &write|
      original.call do |records, scope|
        write.call(records, scope)
        raise IOError, "child approval write rolled back"
      end
    end
    expect { retain(authority) }.to raise_error(IOError)
    expect(@proof.reconcile(persistence: persistence).disposition).to eq(:not_committed)
  end

  it "guards both Agent identities before commit and before later readback" do
    authority = capture
    expect(persistence).to receive(:guard_agents).with(anything, agent_ids: authority.agent_ids).ordered.and_call_original
    expect(persistence).to receive(:guard_agents).with(anything, agent_ids: authority.agent_ids).ordered.and_call_original
    retain(authority)
    expect(@proof.reconcile(persistence: persistence).disposition).to eq(:committed)
  end

  it "rejects a missing relation before returning authority" do
    expect { capture { nil } }.to raise_error(Phronomy::AgentBusyError)
  end

  it "rejects stale parent revisions even if a relation reader returns an older wait" do
    expect { capture(parent_revision: parent_execution.execution_revision + 1) }
      .to raise_error(Phronomy::Persistence::StateConflictError)
  end

  it "rejects a wait belonging to another child incarnation" do
    expect { capture(child_agent_id: parent.agent_id) }.to raise_error(Phronomy::Persistence::StateConflictError)
  end

  it "rejects cancelled parent authority before queueing a decision" do
    persistence.request_cancellation(agent_id: parent.agent_id, execution_id: parent_execution.execution_id)
    expect { capture }.to raise_error(Phronomy::AgentBusyError)
  end

  it "rejects authority capture inside an unrelated outer transaction" do
    persistence.coordinator.atomic do
      expect(persistence).not_to receive(:guard_agents)
      expect { capture }.to raise_error(Phronomy::Persistence::TransactionError)
    end
  end

  it "rejects a changed parent before encoding or writing the child approval" do
    authority = capture
    change_parent_execution(metadata: parent_execution.metadata.merge("changed" => true))
    expect { retain(authority) }.to raise_error(Phronomy::Persistence::StateConflictError)
    expect(@proof).to be_nil
    expect(persistence.executions.load(child_execution.execution_id).to_h).to eq(child_execution.to_h)
  end

  it "does not use a newly captured authority for a different child request" do
    authority = capture
    expect(persistence).not_to receive(:transaction)
    newer = child_execution.with(execution_revision: child_execution.execution_revision + 1)
    expect { retain(authority, command.with(execution: newer, expected_execution_revision: newer.execution_revision)) }
      .to raise_error(Phronomy::Persistence::StateConflictError)
    other = child_execution.with(execution_revision: child_execution.execution_revision,
      approval_request: approval_request.merge("id" => "another-approval"))
    expect { retain(authority, command.with(execution: other, approval_request_id: "another-approval")) }
      .to raise_error(Phronomy::Persistence::StateConflictError)
  end

  it "does not accept committed child post-state after parent revision changes" do
    authority = capture
    retain(authority)
    change_parent_execution(metadata: parent_execution.metadata.merge("changed" => true))
    expect(@proof.reconcile(persistence: persistence).disposition).to eq(:unknown)
  end

  it "does not accept committed child post-state after parent cancellation" do
    authority = capture
    retain(authority)
    persistence.request_cancellation(agent_id: parent.agent_id, execution_id: parent_execution.execution_id)
    expect(@proof.reconcile(persistence: persistence).disposition).to eq(:unknown)
  end

  it "does not accept committed child post-state after a parent hold disappears" do
    authority = capture
    retain(authority)
    persistence.transaction { |records| records.retentions.release(agent_id: parent.agent_id, owner_key: parent_hold.owner_key) }
    expect(@proof.reconcile(persistence: persistence).disposition).to eq(:unknown)
  end

  it "compares opaque participant content without importing its implementation" do
    authority = capture
    retain(authority)
    reference = parent_execution.metadata.fetch("execution_extension").fetch("state_ref")
    allow(persistence).to receive(:participate).and_wrap_original do |original, scope, &read|
      original.call(scope) do |records|
        allow(records.contents).to receive(:fetch_json).with(reference).and_return(parent_state.merge("opaque" => "changed"))
        read.call(records)
      end
    end
    expect(@proof.reconcile(persistence: persistence).disposition).to eq(:unknown)
  end

  it "rejects replay of captured parent authority against another Store" do
    authority = capture
    other = Phronomy::PersistenceComposition.in_memory.agent
    expect do
      Phronomy::Agent::ApprovalResumeCommit.new(agent_id: child.agent_id, persistence: other)
        .commit_retained(command, parent_evidence: authority)
    end.to raise_error(Phronomy::Persistence::StateConflictError)
  end
  it "rejects a removed child hold after relation capture without creating a decision" do
    authority = capture
    persistence.transaction { |records| records.retentions.release(agent_id: child.agent_id, owner_key: child_hold.owner_key) }
    expect { retain(authority) }.to raise_error(Phronomy::Persistence::StateConflictError, /child approval authority changed/)
    expect(@proof).to be_nil
    expect(persistence.executions.load(child_execution.execution_id).to_h).to eq(child_execution.to_h)
  end

  it "rejects a new child hold after relation capture without adopting its different owner" do
    authority = capture
    foreign = Phronomy::Agent::Retention.new(agent_id: child.agent_id,
      execution_id: child_execution.execution_id, owner_key: "new-owner")
    persistence.transaction { |records| records.retentions.retain(foreign) }
    expect { retain(authority) }.to raise_error(Phronomy::Persistence::StateConflictError, /child approval authority changed/)
    expect(@proof).to be_nil
    expect(persistence.executions.load(child_execution.execution_id).to_h).to eq(child_execution.to_h)
  end

  it "does not adopt cancellation newly requested after the hosted relation was captured" do
    authority = capture
    persistence.request_cancellation(agent_id: child.agent_id, execution_id: child_execution.execution_id)
    expect { retain(authority) }.to raise_error(Phronomy::Persistence::StateConflictError, /child approval authority changed/)
    expect(@proof).to be_nil
    expect(persistence.executions.load(child_execution.execution_id).to_h).to eq(child_execution.to_h)
  end
end
