# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::ApprovalPersistenceEvidence do
  let(:persistence) { Phronomy::PersistenceComposition.in_memory.agent }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "retained-approval-proof", version: 1
    end
  end
  let(:agent) { agent_class.create(agent_id: "approval-proof-agent", persistence: persistence) }
  let(:writer) { Phronomy::Agent::ApprovalResumeCommit.new(agent_id: agent.agent_id, persistence: persistence) }
  let(:batch_key) { Phronomy::Agent::ExecutionMetadata::TOOL_BATCH_METADATA_KEY }
  let(:approval_request) do
    item = Phronomy::Agent::ToolApprovalRequest::Item.new(
      tool_invocation_id: "tool-1", tool_call_id: "call-1", tool_name: "lookup",
      arguments: {"query" => "input"}, facts: {}, reason: "approval required", origin: :local, metadata: {}
    )
    Phronomy::Agent::RecoverySupport.canonical_copy(
      Phronomy::Agent::ToolApprovalRequest.new(execution_id: "approval-proof-execution",
        items: [item], id: "approval-proof-request", created_at: Time.utc(2026, 11, 24)).to_h
    )
  end
  let(:execution) do
    input = Phronomy::Agent::JournalRecord.new(agent_id: agent.agent_id,
      execution_id: "approval-proof-execution", kind: :user_message, channel: :llm,
      role: :user, content_ref: persistence.contents.put_text("input"),
      context_generation: agent.agent_root.transcript_generation, context_candidate: true)
    Phronomy::Agent::AgentExecution.start(agent_root: agent.agent_root,
      input_record: input, execution_id: "approval-proof-execution")
      .with(status: :active).with(status: :suspended, phase: :approval,
        approval_request: approval_request,
        metadata: {batch_key => [{"saved" => "original"}], "keep" => "metadata"})
  end
  let(:snapshot) { [{"tool_invocation_id" => "tool-1", "status" => "awaiting_approval"}] }

  def command(**changes)
    Phronomy::Agent::ApprovalResumeCommit::Command.new(
      execution_id: execution.execution_id, expected_execution_revision: execution.execution_revision,
      root: agent.agent_root, execution: execution, approval_request_id: "approval-proof-request",
      approved: true, tool_batch_snapshot: snapshot, **changes
    )
  end

  def retain(operation = command)
    writer.commit_retained(operation, on_outcome: ->(value) { @outcome = value },
      on_evidence: ->(value) { @evidence = value })
  end

  def lose_response
    allow(persistence).to receive(:transaction).and_wrap_original do |original, &write|
      original.call(&write)
      raise IOError, "approval response lost"
    end
  end

  def rollback_write
    allow(persistence).to receive(:transaction).and_wrap_original do |original, &write|
      original.call do |records, scope|
        write.call(records, scope)
        raise IOError, "approval transaction rolled back"
      end
    end
  end

  def alter_observed_record(repository, value)
    allow(persistence).to receive(:participate).and_wrap_original do |original, scope, &read|
      original.call(scope) do |records|
        allow(records.public_send(repository)).to receive(:load).and_return(value)
        read.call(records)
      end
    end
  end

  before do
    persistence.transaction { |records| records.executions.create_active(execution) }
  end

  [true, false].each do |approved|
    it "captures and proves approved=#{approved} without changing the legacy result shape" do
      result = retain(command(approved: approved))
      expect(result).to be_a(Phronomy::Agent::ApprovalResumeCommit::Result)
      expect(@outcome).to equal(result)
      expect(@evidence.outcome).to equal(result)
      expect(@evidence.before.fetch(:agent).fetch(0)).to eq(agent.agent_root.to_h)
      expect(@evidence.before.fetch(:agent).fetch(1)).to eq(execution.to_h)
      expect(@evidence.after.fetch(:agent).fetch(1)).to eq(result.execution.to_h)
      expect(@evidence.before.fetch(:agent).fetch(1).fetch("metadata").fetch(batch_key))
        .to eq([{"saved" => "original"}])
      expect(@evidence.after.fetch(:agent).fetch(1).fetch("metadata").fetch(batch_key)).to eq(snapshot)
      expect(@evidence.after.fetch(:agent).fetch(2)).to eq([])
      expect(@evidence.after.fetch(:agent).fetch(4)).to be(false)
      expect(@evidence.after.fetch(:journal_head)).to eq(agent.agent_root.journal_position)
      expect(@evidence.after.fetch(:retentions)).to eq([])
      expect(@evidence.approved).to be(approved)
      expect(@evidence.approval_request_id).to eq("approval-proof-request")
      expect(@evidence.decision).to equal(result.execution.working_records.last)
      expect(@evidence.decision_bytes).to eq(Phronomy::CanonicalJSON.dump(
        "approval_request_id" => "approval-proof-request", "approved" => approved
      ))
      proof = @evidence.reconcile(persistence: persistence)
      expect(proof.disposition).to eq(:committed)
      expect(proof.evidence).to equal(@evidence)
      expect(proof.original_error).to be_nil
      expect(proof.read_error).to be_nil
      expect(@evidence).not_to respond_to(:retry)
    end
  end

  it "retains detached immutable decision and Tool facts" do
    retain
    snapshot.first["status"] = "changed by caller"
    expect(@evidence.outcome.execution.metadata.fetch(batch_key).first.fetch("status")).to eq("awaiting_approval")
    expect(@evidence).to be_frozen
    expect(@evidence.before).to be_frozen
    expect(@evidence.after.fetch(:agent).fetch(1).fetch("working_records")).to be_frozen
    expect(@evidence.decision_bytes).to be_frozen
    expect(@evidence.attempt_id).to be_frozen
  end

  it "publishes outcome then proof once and never repeats either collector during reconciliation" do
    calls = []
    proof = nil
    result = writer.commit_retained(command,
      on_outcome: ->(value) { calls << [:outcome, value] },
      on_evidence: ->(value) {
        calls << [:evidence, value]
        proof = value
      })
    2.times { expect(proof.reconcile(persistence: persistence).disposition).to eq(:committed) }
    expect(calls).to eq([[:outcome, result], [:evidence, proof]])
  end

  it "propagates a collector failure after success without rolling back the decision" do
    expect do
      writer.commit_retained(command, on_evidence: ->(_) { raise IOError, "collector failed" })
    end.to raise_error(IOError, /collector failed/)
    expect(persistence.executions.load(execution.execution_id).status).to eq(:active)
    expect(persistence.agents.load(agent.agent_id).agent_revision).to eq(agent.agent_root.agent_revision + 1)
  end

  it "publishes complete captured facts after a lost response without automatic observation or write replay" do
    lose_response
    expect(described_class).to receive(:read).twice.and_call_original
    expect { retain }.to raise_error(IOError, /response lost/)
    expect(persistence).to have_received(:transaction).once
    expect(@evidence.outcome).to equal(@outcome)
    expect(persistence.executions.load(execution.execution_id).working_records.count { |r| r.kind == :approval_decided }).to eq(1)
  end

  it "classifies a settled response loss as committed without encoding, callbacks or writes" do
    lose_response
    error = nil
    begin
      retain
    rescue IOError => failure
      error = failure
    end
    allow(Phronomy::CanonicalJSON).to receive(:dump).and_call_original
    expect(Phronomy::CanonicalJSON).not_to receive(:dump).with(
      "approval_request_id" => "approval-proof-request", "approved" => true
    )
    expect(writer).not_to receive(:commit_retained)
    expect(persistence).not_to receive(:transaction)
    result = @evidence.reconcile(persistence: persistence, original_error: error)
    expect(result.disposition).to eq(:committed)
    expect(result.original_error).to equal(error)
  end

  it "classifies complete rollback as not committed while retaining the intended result" do
    rollback_write
    expect { retain }.to raise_error(IOError, /rolled back/)
    expect(@outcome.execution.status).to eq(:active)
    expect(@evidence.reconcile(persistence: persistence).disposition).to eq(:not_committed)
    expect(persistence.executions.load(execution.execution_id).to_h).to eq(execution.to_h)
  end

  it "captures proof before an execution save fails" do
    allow(persistence).to receive(:transaction).and_wrap_original do |original, &write|
      original.call do |records, scope|
        allow(records.executions).to receive(:save).and_raise(IOError, "execution save failed")
        write.call(records, scope)
      end
    end
    expect { retain }.to raise_error(IOError, /execution save/)
    expect(@evidence.reconcile(persistence: persistence).disposition).to eq(:not_committed)
  end

  it "captures proof before a root save fails and rolls back the execution" do
    allow(persistence).to receive(:transaction).and_wrap_original do |original, &write|
      original.call do |records, scope|
        allow(records.agents).to receive(:save).and_raise(IOError, "root save failed")
        write.call(records, scope)
      end
    end
    expect { retain }.to raise_error(IOError, /root save/)
    expect(@evidence.reconcile(persistence: persistence).disposition).to eq(:not_committed)
  end

  it "does not invent complete evidence when decision material was not captured" do
    allow(persistence).to receive(:transaction).and_wrap_original do |original, &write|
      original.call do |records, scope|
        allow(records.contents).to receive(:put).and_raise(IOError, "content unavailable")
        write.call(records, scope)
      end
    end
    expect { retain }.to raise_error(IOError, /content unavailable/)
    expect(@evidence).to be_nil
    expect(@outcome).to be_nil
  end

  it "preserves the original write error when a collector fails" do
    lose_response
    expect do
      writer.commit_retained(command, on_outcome: ->(_) { raise "collector failed" })
    end.to raise_error(IOError, /response lost/)
  end

  it "reports an authoritative read failure as unknown with both diagnostics" do
    retain
    original = IOError.new("response lost")
    failure = IOError.new("authoritative read unavailable")
    allow(persistence.coordinator).to receive(:atomic).and_raise(failure)
    result = @evidence.reconcile(persistence: persistence, original_error: original)
    expect(result.disposition).to eq(:unknown)
    expect(result.original_error).to equal(original)
    expect(result.read_error).to equal(failure)
  end

  it "rejects a foreign Store before any transaction, including the same backend" do
    retain
    other = Phronomy::PersistenceComposition.build(backend: persistence.coordinator.backend).agent
    expect(other.coordinator).not_to receive(:atomic)
    result = @evidence.reconcile(persistence: other)
    expect(result.disposition).to eq(:unknown)
    expect(result.read_error).to be_a(Phronomy::Persistence::StateConflictError)
  end

  it "rejects nested write and read transactions before guards or evidence reads" do
    retain
    expect(persistence).not_to receive(:guard_agents)
    expect(described_class).not_to receive(:read)
    persistence.coordinator.atomic do
      result = @evidence.reconcile(persistence: persistence)
      expect(result.disposition).to eq(:unknown)
      expect(result.read_error).to be_a(Phronomy::Persistence::TransactionError)
      expect { writer.commit_retained(command) }.to raise_error(Phronomy::Persistence::TransactionError)
    end
  end

  it "guards before capturing any pre-state or authoritative reconciliation" do
    calls = []
    allow(persistence).to receive(:guard_agents).and_wrap_original do |original, *args, **kwargs|
      calls << :guard
      original.call(*args, **kwargs)
    end
    allow(described_class).to receive(:read).and_wrap_original do |original, **kwargs|
      calls << :read
      original.call(**kwargs)
    end
    retain
    @evidence.reconcile(persistence: persistence)
    expect(calls).to eq([:guard, :read, :read, :guard, :read])
  end

  it "rejects mismatched operation identities before persistence" do
    expect(persistence).not_to receive(:transaction)
    expect { retain(command(execution_id: "another-execution")) }.to raise_error(ArgumentError)
    expect { retain(command(expected_execution_revision: execution.execution_revision + 1)) }.to raise_error(ArgumentError)
    expect { retain(command(approval_request_id: "another-request")) }.to raise_error(ArgumentError)
    expect { retain(command(approved: nil)) }.to raise_error(ArgumentError)
  end

  %w[reservation execution_extension cancellation_requested].each do |key|
    it "rejects #{key} before persistence" do
      changed = execution.with(execution_revision: execution.execution_revision,
        metadata: execution.metadata.merge(key => true))
      expect(persistence).not_to receive(:transaction)
      expect { retain(command(execution: changed)) }.to raise_error(ArgumentError)
    end
  end

  it "rejects a changed suspended pre-state before encoding the decision" do
    newer = execution.with(metadata: execution.metadata.merge("competitor" => true))
    persistence.transaction do |records|
      records.executions.save(execution.execution_id,
        expected_revision: execution.execution_revision, execution: newer)
    end
    expect { retain }.to raise_error(Phronomy::Persistence::StateConflictError)
    expect(@evidence).to be_nil
    expect(persistence.executions.load(execution.execution_id).to_h).to eq(newer.to_h)
  end

  it "rejects same-revision root content divergence" do
    retain
    altered = @outcome.root.with(agent_revision: @outcome.root.agent_revision,
      updated_at: Time.utc(2001, 1, 1))
    alter_observed_record(:agents, altered)
    expect(@evidence.reconcile(persistence: persistence).disposition).to eq(:unknown)
  end

  it "rejects same-revision execution content divergence" do
    retain
    altered = @outcome.execution.with(execution_revision: @outcome.execution.execution_revision,
      metadata: @outcome.execution.metadata.merge("foreign" => true))
    alter_observed_record(:executions, altered)
    expect(@evidence.reconcile(persistence: persistence).disposition).to eq(:unknown)
  end

  it "rejects a replaced working decision record even when revisions and decision bytes match" do
    retain
    replacement = Phronomy::Agent::JournalRecord.from_h(@evidence.decision.to_h.merge("record_id" => "foreign-record"))
    altered = @outcome.execution.with(execution_revision: @outcome.execution.execution_revision,
      working_records: @outcome.execution.working_records[0...-1] + [replacement])
    alter_observed_record(:executions, altered)
    expect(@evidence.reconcile(persistence: persistence).disposition).to eq(:unknown)
  end

  it "rejects altered decision bytes even when root and execution match exactly" do
    retain
    allow(persistence).to receive(:participate).and_wrap_original do |original, scope, &read|
      original.call(scope) do |records|
        allow(records.contents).to receive(:fetch).with(@evidence.decision.content_ref).and_return("foreign bytes")
        read.call(records)
      end
    end
    result = @evidence.reconcile(persistence: persistence)
    expect(result.disposition).to eq(:unknown)
    expect(result.read_error).to be_a(Phronomy::ContentStore::IntegrityError)
  end

  it "rejects an unexpected journal suffix even when the root position did not move" do
    retain
    persistence.transaction do |records|
      records.journals.append(agent.agent_id, expected_position: agent.agent_root.journal_position,
        records: [@evidence.decision])
    end
    expect(@evidence.reconcile(persistence: persistence).disposition).to eq(:unknown)
  end

  it "rejects a changed journal head even when a partial reader hides its suffix" do
    retain
    allow(persistence).to receive(:participate).and_wrap_original do |original, scope, &read|
      original.call(scope) do |records|
        allow(records.journals).to receive(:head).and_return(agent.agent_root.journal_position + 1)
        read.call(records)
      end
    end
    expect(@evidence.reconcile(persistence: persistence).disposition).to eq(:unknown)
  end

  it "does not mistake durable cancellation for the captured post-state" do
    retain
    persistence.request_cancellation(agent_id: agent.agent_id, execution_id: execution.execution_id)
    expect(@evidence.reconcile(persistence: persistence).disposition).to eq(:unknown)
  end

  {lose_response: :committed, rollback_write: :not_committed}.each do |fault, disposition|
    it "preserves an already requested cancellation when the decision is #{disposition}" do
      persistence.request_cancellation(agent_id: agent.agent_id, execution_id: execution.execution_id)
      public_send(fault)

      expect { retain }.to raise_error(IOError)

      expect(@evidence.before.fetch(:agent).fetch(4)).to be(true)
      expect(@evidence.after.fetch(:agent).fetch(4)).to be(true)
      expect(@evidence.reconcile(persistence: persistence).disposition).to eq(disposition)
      allow(persistence).to receive(:transaction).and_call_original
      expect(persistence.cancellation_requested?(agent_id: agent.agent_id,
        execution_id: execution.execution_id)).to be(true)
    end
  end

  it "does not mistake a new retention for the captured post-state" do
    retain
    persistence.transaction do |records|
      records.retentions.retain(Phronomy::Agent::Retention.new(agent_id: agent.agent_id,
        execution_id: execution.execution_id, owner_key: "foreign-owner"))
    end
    expect(@evidence.reconcile(persistence: persistence).disposition).to eq(:unknown)
  end

  it "preserves unrelated preexisting transcript retention through a standalone decision" do
    retention = Phronomy::Agent::Retention.new(agent_id: agent.agent_id,
      execution_id: "retained-history", owner_key: "transcript-reader")
    persistence.transaction { |records| records.retentions.retain(retention) }
    result = retain
    expect(result.execution.status).to eq(:active)
    expect(@evidence.before.fetch(:retentions)).to eq([retention])
    expect(@evidence.after.fetch(:retentions)).to eq([retention])
    expect(@evidence.reconcile(persistence: persistence).disposition).to eq(:committed)
    expect(persistence.retentions.list(agent.agent_id)).to eq([retention])
  end
end
