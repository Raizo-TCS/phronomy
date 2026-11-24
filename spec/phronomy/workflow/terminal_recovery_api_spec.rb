# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Workflow terminal recovery observation contracts" do
  let(:workflow_id) { +"workflow-7" }
  let(:recovery_id) { +"recovery-9" }
  let(:recovery) do
    double("retained recovery", workflow_instance_id: workflow_id, recovery_id: recovery_id)
  end

  it "retains initial failure and immediate cause across deferred error delivery" do
    original = IOError.new("save response lost")
    current = IOError.new("authoritative read unavailable")
    error = Phronomy::WorkflowTerminalRecoveryError.new(
      recovery: recovery, error: current, original_error: original
    )
    observation = Phronomy::TaskResult.failed(error)

    expect { observation.wait_result }.to raise_error do |delivered|
      expect(delivered).to equal(error)
      expect(delivered.code).to eq("workflow.terminal_recovery")
      expect(delivered.recovery).to equal(recovery)
      expect(delivered.original_error).to equal(original)
      expect(delivered.cause).to equal(current)
      expect(delivered).not_to be_a(Phronomy::CancellationError)
    end
    expect(Phronomy::Error.diagnostic(error).fetch("cause").fetch("message"))
      .to eq("authoritative read unavailable")
  end

  it "copies diagnostic identity without losing the original capability" do
    error = Phronomy::WorkflowTerminalRecoveryError.new(recovery: recovery, error: IOError.new)
    workflow_id.replace("another-workflow")
    recovery_id.replace("another-recovery")

    expect(error.workflow_instance_id).to eq("workflow-7")
    expect(error.recovery_id).to eq("recovery-9")
    expect(error.workflow_instance_id).to be_frozen
    expect(error.recovery_id).to be_frozen
    expect(error.recovery).to equal(recovery)
  end

  it "preserves a confirmed fact while application and ownership remain unfinished" do
    failure = RuntimeError.new("context materialization failed")
    previous = Phronomy::WorkflowTerminalRecoveryResult.new(
      recovery: recovery, outcome: :confirmed_post, revision: 3,
      application_state: :pending, ownership_state: :retained, error: failure
    )
    subsequent = Phronomy::WorkflowTerminalRecoveryResult.new(
      recovery: recovery, outcome: :confirmed_post, revision: 3,
      application_state: :applied, ownership_state: :released, context: {value: 7}
    )

    expect(previous).to be_frozen
    expect(previous.outcome).to eq(:confirmed_post)
    expect(previous.application_state).to eq(:pending)
    expect(previous.ownership_state).to eq(:retained)
    expect(previous.error).to equal(failure)
    expect(subsequent.application_state).to eq(:applied)
    expect(subsequent.ownership_state).to eq(:released)
    expect(subsequent.context).to eq(value: 7)
    expect(subsequent.recovery).to equal(previous.recovery)
  end

  it "refuses to represent release before application or while persistence is unclassified" do
    expect do
      Phronomy::WorkflowTerminalRecoveryResult.new(
        recovery: recovery, outcome: :confirmed_post, revision: 1,
        application_state: :pending, ownership_state: :released
      )
    end.to raise_error(ArgumentError, /before application/)

    expect do
      Phronomy::WorkflowTerminalRecoveryResult.new(
        recovery: recovery, outcome: :unresolved,
        application_state: :applied, ownership_state: :released
      )
    end.to raise_error(ArgumentError, /unclassified/)
  end

  it "does not present an unknown or absent save as a saved context" do
    expect do
      Phronomy::WorkflowTerminalRecoveryResult.new(
        recovery: recovery, outcome: :confirmed_pre, context: {value: 7},
        application_state: :applied, ownership_state: :released
      )
    end.to raise_error(ArgumentError, /only confirmed Workflow post-state/)

    expect do
      Phronomy::WorkflowTerminalRecoveryResult.new(
        recovery: recovery, outcome: :confirmed_post, revision: nil,
        application_state: :pending, ownership_state: :retained
      )
    end.to raise_error(ArgumentError, /positive revision/)
  end
end
