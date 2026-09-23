# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::ApprovalResumeCommit do
  let(:persistence) { Phronomy::Persistence.in_memory }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "approval-commit-contract", version: 1
    end
  end
  let(:agent) { agent_class.create(agent_id: "approval-agent", persistence: persistence) }
  let(:worker) { described_class.new(agent_id: agent.agent_id, persistence: persistence) }
  let(:batch_key) { Phronomy::Agent::ExecutionMetadata::TOOL_BATCH_METADATA_KEY }
  let(:approval_request) do
    item = Phronomy::Agent::ToolApprovalRequest::Item.new(
      tool_invocation_id: "restored-child", tool_call_id: "call-1",
      tool_name: "lookup", arguments: {"query" => "restored"},
      facts: {}, reason: "approval required", origin: :local, metadata: {}
    )
    Phronomy::Agent::RecoverySupport.canonical_copy(
      Phronomy::Agent::ToolApprovalRequest.new(execution_id: "approval-execution",
        items: [item], id: "approval-1", created_at: Time.utc(2026, 9, 22)).to_h
    )
  end
  let(:execution) do
    record = Phronomy::Agent::JournalRecord.new(
      agent_id: agent.agent_id, execution_id: "approval-execution",
      kind: :user_message, channel: :llm, role: :user,
      content_ref: persistence.contents.put_text("input"),
      context_generation: agent.agent_root.transcript_generation,
      context_candidate: true
    )
    Phronomy::Agent::AgentExecution.start(agent_root: agent.agent_root,
      input_record: record, execution_id: "approval-execution")
      .with(status: :active).with(status: :suspended, phase: :approval,
        approval_request: approval_request,
        metadata: {batch_key => [{"saved" => "old"}], "keep" => "metadata"})
  end
  let(:snapshot) do
    Phronomy::Values::Immutable.copy([
      {"tool_invocation_id" => "restored-child", "status" => "awaiting_approval",
       "arguments" => {"query" => "restored"}}
    ])
  end

  def command(**changes)
    described_class::Command.new(execution_id: execution.execution_id,
      expected_execution_revision: execution.execution_revision,
      root: agent.agent_root, execution: execution,
      approval_request_id: "approval-1", approved: true,
      tool_batch_snapshot: snapshot, **changes)
  end

  before do
    persistence.transaction { |tx| tx.executions.create_active(execution) }
  end

  after do
    Phronomy.reset_runtime!
  end

  [true, false].each do |approved|
    it "atomically records approved=#{approved} with the snapshot and advances both revisions once" do
      operation = command(approved: approved)
      root = agent.agent_root
      result = worker.commit(operation)
      saved = persistence.executions.load(execution.execution_id)
      decision = saved.working_records.last

      expect(saved.to_h).to eq(result.execution.to_h)
      expect(saved.status).to eq(:active)
      expect(saved.phase).to eq(:resuming)
      expect(saved.execution_revision).to eq(execution.execution_revision + 1)
      expect(saved.approval_request).to eq(execution.approval_request.merge("approved" => approved))
      expect(saved.metadata).to eq(batch_key => snapshot, "keep" => "metadata")
      expect(decision.kind).to eq(:approval_decided)
      expect(decision.channel).to eq(:approval)
      expect(decision.context_candidate).to be(false)
      expect(persistence.contents.fetch_json(decision.content_ref))
        .to eq("approval_request_id" => "approval-1", "approved" => approved)
      expect(result.root.agent_revision).to eq(root.agent_revision + 1)
      expect(result.root.lifecycle_status).to eq(:active)
      expect(persistence.agents.load(agent.agent_id).to_h).to eq(result.root.to_h)
      expect(agent.agent_root).to equal(root)
      expect(operation.execution).to equal(execution)
      expect(execution.metadata[batch_key]).to eq([{"saved" => "old"}])
    end
  end

  it "retains saved recovery facts when no invocation snapshot was captured" do
    result = worker.commit(command(tool_batch_snapshot: nil))
    expect(result.execution.metadata).to eq(execution.metadata)
  end

  it "replaces previous recovery facts when the captured batch is empty" do
    result = worker.commit(command(tool_batch_snapshot: [].freeze))
    expect(result.execution.metadata[batch_key]).to eq([])
  end

  it "validates the approval target before entering Persistence (F0)" do
    expect(persistence).not_to receive(:transaction)
    expect { worker.commit(command(approval_request_id: "old-request")) }
      .to raise_error(ArgumentError, /does not match/)
  end

  it "rejects a competing revision without overwriting the winner's snapshot (F2/G8)" do
    first = command
    second = command(tool_batch_snapshot: Phronomy::Values::Immutable.copy([{"winner" => "second"}]))
    winner = worker.commit(second)

    expect { worker.commit(first) }.to raise_error(Phronomy::Storage::ConflictError)
    expect(persistence.executions.load(execution.execution_id).to_h).to eq(winner.execution.to_h)
    expect(persistence.agents.load(agent.agent_id).to_h).to eq(winner.root.to_h)
    expect(winner.execution.working_records.count { |record| record.kind == :approval_decided }).to eq(1)
  end

  it "rolls back the decision and Execution update when Root CAS fails (F2/G5/G8)" do
    operation = command
    concurrent_root = operation.root.with(agent_revision: operation.root.agent_revision + 1)
    persistence.transaction do |tx|
      tx.agents.save(agent.agent_id, expected_revision: operation.root.agent_revision, root: concurrent_root)
    end

    expect { worker.commit(operation) }.to raise_error(Phronomy::Storage::ConflictError)
    expect(persistence.executions.load(execution.execution_id).to_h).to eq(execution.to_h)
    expect(persistence.agents.load(agent.agent_id).to_h).to eq(concurrent_root.to_h)
  end

  it "does not retry or claim a confirmed result after a lost commit response (F1)" do
    operation = command
    allow(persistence).to receive(:transaction).and_wrap_original do |original, &write|
      original.call(&write)
      raise IOError, "approval response lost after commit"
    end
    expect(persistence).not_to receive(:executions)
    expect(persistence).not_to receive(:agents)

    expect { worker.commit(operation) }.to raise_error(IOError, /response lost/)
    expect(persistence).to have_received(:transaction).once
    # Read through a separate facade only as a test observer, never as a worker retry.
    observer = Phronomy::Persistence.new(backend: persistence.backend)
    saved = observer.executions.load(execution.execution_id)
    expect(saved.status).to eq(:active)
    expect(saved.execution_revision).to eq(execution.execution_revision + 1)
    expect(saved.metadata[batch_key]).to eq(snapshot)
    expect(observer.agents.load(agent.agent_id).agent_revision).to eq(operation.root.agent_revision + 1)
  end

  it "does not share operation state across later approval requests" do
    resumed = worker.commit(command)
    suspended = resumed.execution.with(status: :suspended, phase: :approval,
      approval_request: execution.approval_request.merge("id" => "approval-2"))
    persistence.transaction do |tx|
      tx.executions.save(execution.execution_id,
        expected_revision: resumed.execution.execution_revision, execution: suspended)
    end
    second = command(execution: suspended, root: resumed.root,
      expected_execution_revision: suspended.execution_revision,
      approval_request_id: "approval-2", tool_batch_snapshot: [].freeze)
    next_result = worker.commit(second)
    expect(next_result.execution.metadata[batch_key]).to eq([])
    expect(resumed.execution.metadata[batch_key]).to eq(snapshot)
    expect(next_result.execution.working_records.count { |record| record.kind == :approval_decided }).to eq(2)
  end

  it "keeps internal aliases while making the canonical type names and snapshot field explicit" do
    expect(Phronomy::Agent::ExecutionCoordinator::ResumeCommitCommand).to equal(described_class::Command)
    expect(Phronomy::Agent::ExecutionCoordinator::ResumeCommitResult).to equal(described_class::Result)
    expect(described_class::Command.name).to eq("Phronomy::Agent::ApprovalResumeCommit::Command")
    expect(described_class::Command.members).to eq(%i[execution_id expected_execution_revision
      root execution approval_request_id approved tool_batch_snapshot])
    expect(described_class::Result.members).to eq(%i[execution root])
  end
end
