# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent final-or-wait recovery public contract" do
  let(:agent) { Phronomy::Agent::Base.allocate }
  let(:owner) do
    Phronomy::Agent::OutcomeRecoveryOperation.allocate.tap do |operation|
      allow(operation).to receive_messages(agent_id: "parent", execution_id: "parent-execution",
        recovery_id: "outcome-recovery", recovery_kind: :outcome)
      allow(operation).to receive(:belongs_to?).with(agent).and_return(true)
    end
  end
  let(:recovery) do
    Phronomy::Agent::OutcomeRecovery.send(:new, owner).tap do |reference|
      allow(owner).to receive(:recovery).and_return(reference)
    end
  end
  let(:result_values) do
    {recovery: recovery, outcome: :confirmed_post, saved_outcome: :terminal,
     application_state: :applied, ownership_state: :released, revision: 2,
     execution: terminal_execution, submission_state: :admitted}
  end
  let(:terminal_execution) do
    Phronomy::Agent::ExecutionObservation.new(agent_id: "parent", execution_id: "parent-execution",
      status: :completed, result: "report ready", error: nil, reservation: nil,
      transfer_receipt: nil, cancellation_requested: false)
  end
  let(:approval_request) do
    item = Phronomy::Agent::ToolApprovalRequest::Item.new(tool_invocation_id: "protected-tool",
      tool_call_id: "call-1", tool_name: "publish_report", arguments: {}, facts: {},
      reason: "Requires approval", origin: :local, metadata: {})
    Phronomy::Agent::ToolApprovalRequest.new(execution_id: "parent-execution", items: [item])
  end

  it "looks up local custody without constructing a Runtime" do
    expect(Phronomy::Runtime).not_to receive(:instance)
    expect(agent.pending_outcome_recovery(execution_id: "parent-execution")).to be_nil
    [nil, "", 1].each do |invalid|
      expect { agent.pending_outcome_recovery(execution_id: invalid) }.to raise_error(ArgumentError)
    end
  end

  it "keeps the reference constructor private and preserves exact operation identity" do
    expect { Phronomy::Agent::OutcomeRecovery.new(owner) }.to raise_error(NoMethodError)
    expect(recovery).to be_frozen
    expect(recovery.agent_id).to eq("parent")
    expect(recovery.execution_id).to eq("parent-execution")
    expect(recovery.recovery_id).to eq("outcome-recovery")
  end

  {reconcile_outcome: :reconcile, retry_outcome: :retry, retry_outcome_submission: :submission}.each do |method, kind|
    it "uses a fresh observation and host-thread wait for #{method}" do
      first = Phronomy::TaskResult.completed(:first)
      second = Phronomy::TaskResult.completed(:second)
      expect(owner).to receive(:observe).with(kind).ordered.and_return(first)
      expect(owner).to receive(:observe).with(kind).ordered.and_return(second)
      expect(agent.public_send("#{method}_async", recovery: recovery)).to equal(first)
      expect(agent).to receive(:_check_event_loop_reentrancy).with(method, :"#{method}_async")
      expect(agent.public_send(method, recovery: recovery)).to eq(:second)
    end
  end

  it "rejects a terminal capability and another Agent incarnation" do
    terminal = Phronomy::Agent::TerminalRecovery.send(:new, owner)
    expect { agent.reconcile_outcome_async(recovery: terminal) }.to raise_error(ArgumentError, /OutcomeRecovery/)
    own = recovery
    allow(owner).to receive(:belongs_to?).with(agent).and_return(false)
    expect { agent.retry_outcome_async(recovery: own) }.to raise_error(ArgumentError, /another Agent/)
  end

  it "rejects a capability from a different operation profile" do
    own = recovery
    allow(owner).to receive(:recovery_kind).and_return(:terminal)
    expect { agent.reconcile_outcome_async(recovery: own) }.to raise_error(ArgumentError, /another Agent/)
  end

  it "distinguishes a released terminal result from a released coordination wait" do
    terminal = Phronomy::Agent::OutcomeRecoveryResult.new(**result_values)
    waiting = Phronomy::Agent::OutcomeRecoveryResult.new(**result_values.merge(
      saved_outcome: :coordination_wait, execution: nil
    ))
    expect(terminal.execution).to be_terminal
    expect(terminal.saved_outcome).to eq(:terminal)
    expect(waiting.saved_outcome).to eq(:coordination_wait)
    expect(waiting.ownership_state).to eq(:released)
    expect(waiting.execution).to be_nil
    expect(waiting.approval_request).to be_nil
    expect(waiting).to be_frozen
  end

  it "preserves an exact saved approval request without manufacturing a terminal result" do
    receipt = Phronomy::Agent::OutcomeRecoveryResult.new(**result_values.merge(
      saved_outcome: :approval_wait, execution: nil, approval_request: approval_request
    ))
    expect(receipt.saved_outcome).to eq(:approval_wait)
    expect(receipt.approval_request).to equal(approval_request)
    expect(receipt.execution).to be_nil
    expect(receipt.ownership_state).to eq(:released)
  end

  it "does not attach saved values to an unresolved or confirmed pre-state" do
    %i[confirmed_pre unresolved unavailable].each do |outcome|
      values = {recovery: recovery, outcome: outcome, application_state: :pending, ownership_state: :retained}
      expect(Phronomy::Agent::OutcomeRecoveryResult.new(**values).saved_outcome).to be_nil
      expect { Phronomy::Agent::OutcomeRecoveryResult.new(**values.merge(saved_outcome: :coordination_wait)) }
        .to raise_error(ArgumentError, /only confirmed/)
      expect { Phronomy::Agent::OutcomeRecoveryResult.new(**values.merge(approval_request: approval_request)) }
        .to raise_error(ArgumentError, /only confirmed/)
    end
  end

  it "refuses contradictory wait and terminal receipt payloads" do
    [result_values.merge(saved_outcome: nil), result_values.merge(revision: 0),
      result_values.merge(saved_outcome: :approval_wait), result_values.merge(saved_outcome: :coordination_wait),
      result_values.merge(approval_request: approval_request), result_values.merge(execution: nil)].each do |values|
      expect { Phronomy::Agent::OutcomeRecoveryResult.new(**values) }.to raise_error(ArgumentError)
    end
    other = Phronomy::Agent::ToolApprovalRequest.new(execution_id: "another-execution", items: approval_request.items)
    expect {
      Phronomy::Agent::OutcomeRecoveryResult.new(**result_values.merge(saved_outcome: :approval_wait,
        execution: nil, approval_request: other))
    }.to raise_error(ArgumentError, /exact saved request/)
  end

  it "cannot release custody without applying a confirmed admitted save" do
    expect {
      Phronomy::Agent::OutcomeRecoveryResult.new(**result_values.merge(application_state: :pending))
    }.to raise_error(ArgumentError, /before application/)
    expect {
      Phronomy::Agent::OutcomeRecoveryResult.new(**result_values.merge(submission_state: :not_admitted))
    }.to raise_error(ArgumentError, /unadmitted/)
  end

  it "keeps immediate recovery failure separate from the original save error" do
    original, immediate = IOError.new("save response lost"), IOError.new("readback unavailable")
    error = Phronomy::Agent::OutcomeRecoveryError.new(recovery: recovery, error: immediate, original_error: original)
    expect(error.code).to eq("agent.outcome_recovery")
    expect(error.cause).to equal(immediate)
    expect(error.original_error).to equal(original)
    expect(error.recovery).to equal(recovery)
  end
end
