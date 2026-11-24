# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent approval recovery observation contracts" do
  let(:identities) do
    {agent_id: +"agent-7", execution_id: +"execution-8",
     approval_request_id: +"approval-9", recovery_id: +"recovery-10", approved: false}
  end
  let(:operation) { double("retained approval operation", **identities) }
  let(:recovery) { Phronomy::Agent::ApprovalRecovery.send(:new, operation) }
  let(:pending_values) do
    {recovery: recovery, outcome: :unresolved, application_state: :pending,
     continuation_state: :pending, physical_complete: false}
  end

  def receipt(**changes)
    Phronomy::Agent::ApprovalRecoveryResult.new(**pending_values.merge(changes))
  end

  it "keeps the original capability private and snapshots every diagnostic identity" do
    capability = recovery
    expect { Phronomy::Agent::ApprovalRecovery.new(operation) }.to raise_error(NoMethodError, /private method/)
    expect(capability).to be_frozen
    expect(capability).not_to respond_to(:operation)
    expect(capability.send(:operation)).to equal(operation)
    expect(capability.approved).to be(false)

    identities.each do |name, original|
      next unless original.is_a?(String)
      expected = original.dup
      original.replace("changed identity")
      expect(capability.public_send(name)).to eq(expected)
      expect(capability.public_send(name)).to be_frozen
    end
  end

  it "retains the original failure separately from the immediate observation cause" do
    original = IOError.new("approval save response lost")
    current = IOError.new("approval read unavailable")
    error = Phronomy::Agent::ApprovalRecoveryError.new(
      recovery: recovery, error: current, original_error: original
    )

    expect { Phronomy::TaskResult.failed(error).wait_result }.to raise_error do |delivered|
      expect(delivered).to equal(error)
      expect(delivered.code).to eq("agent.approval_recovery")
      expect(delivered.recovery).to equal(recovery)
      expect(delivered.original_error).to equal(original)
      expect(delivered.cause).to equal(current)
      expect(delivered.approval_request_id).to eq("approval-9")
      expect(delivered.approved).to be(false)
      expect(delivered).not_to be_a(Phronomy::CancellationError)
    end
    expect(Phronomy::Error.diagnostic(error).fetch("cause").fetch("message"))
      .to eq("approval read unavailable")
  end

  it "defaults original_error to the initial failure" do
    failure = IOError.new("approval write uncertain")
    error = Phronomy::Agent::ApprovalRecoveryError.new(recovery: recovery, error: failure)
    expect(error.original_error).to equal(failure)
    expect(error.cause).to equal(failure)
  end

  it "retains a confirmed decision while owner application or continuation is pending" do
    failure = RuntimeError.new("continuation registration unavailable")
    before = receipt(outcome: :confirmed_post, revision: 3, physical_complete: true, error: failure)
    applied = receipt(outcome: :confirmed_post, revision: 3, physical_complete: true,
      application_state: :applied, error: failure)

    [before, applied].each do |value|
      expect(value).to be_frozen
      expect(value.outcome).to eq(:confirmed_post)
      expect(value.continuation_state).to eq(:pending)
      expect(value.execution_task).to be_nil
      expect(value.error).to equal(failure)
      expect(value.physical_complete?).to be(true)
      expect(value.resolved?).to be(false)
      expect(value).not_to respond_to(:ownership_state)
    end
    expect(before.application_state).to eq(:pending)
    expect(applied.application_state).to eq(:applied)
  end

  it "resolves the approval obligation by restoring the original wait and its revision" do
    value = receipt(outcome: :confirmed_pre, revision: 2, physical_complete: true,
      application_state: :applied, continuation_state: :restored)

    expect(value.resolved?).to be(true)
    expect(value.execution_task).to be_nil
    expect(value.revision).to eq(2)
    expect(value.recovery).to equal(recovery)
    expect(value.approval_request_id).to eq("approval-9")
    expect(value.approved).to be(false)
  end

  it "can resolve approval recovery while the resumed execution observation is still pending" do
    execution = Phronomy::TaskResult.deferred
    value = receipt(outcome: :confirmed_post, revision: 3, physical_complete: true,
      application_state: :applied, continuation_state: :resumed, execution_task: execution)

    expect(value.resolved?).to be(true)
    expect(value.physical_complete?).to be(true)
    expect(value.execution_task).to equal(execution)
    expect(execution.status).to eq(:pending)
  end

  it "keeps execution failure separate from the successful recovery receipt" do
    failure = Phronomy::Error.new("authorized continuation failed")
    execution = Phronomy::TaskResult.failed(failure)
    value = receipt(outcome: :confirmed_post, revision: 3, physical_complete: true,
      application_state: :applied, continuation_state: :resumed, execution_task: execution)

    expect(value.resolved?).to be(true)
    expect(value.error).to be_nil
    expect { value.execution_task.wait_result }.to raise_error { |error| expect(error).to equal(failure) }
  end

  it "accepts the exact zero revision of a confirmed initial record" do
    expect(receipt(outcome: :confirmed_pre, revision: 0).revision).to eq(0)
  end

  it "does not treat a saved decision as proof of worker completion" do
    value = receipt(outcome: :confirmed_post, revision: 3)
    expect(value.physical_complete?).to be(false)
    expect(value.resolved?).to be(false)
    expect(value.execution_task).to be_nil
  end

  it "rejects invalid domains and nonboolean physical completion" do
    [{outcome: :unknown}, {application_state: :done}, {continuation_state: :done}].each do |change|
      expect { receipt(**change) }.to raise_error(ArgumentError, /unsupported/)
    end
    [nil, 0, :complete].each do |value|
      expect { receipt(physical_complete: value) }.to raise_error(ArgumentError, /boolean/)
    end
  end

  it "requires the exact confirmed revision and does not invent a revision for an unknown outcome" do
    [nil, -1, "3"].each do |revision|
      expect { receipt(outcome: :confirmed_pre, revision: revision) }
        .to raise_error(ArgumentError, /nonnegative execution revision/)
      expect { receipt(outcome: :confirmed_post, revision: revision) }
        .to raise_error(ArgumentError, /nonnegative execution revision/)
    end
    expect { receipt(revision: 3) }.to raise_error(ArgumentError, /unclassified/)
    expect { receipt(outcome: :unavailable, application_state: :applied) }
      .to raise_error(ArgumentError, /unclassified/)
  end

  it "requires owner application and stopped approval workers before restoring or resuming" do
    expect do
      receipt(outcome: :confirmed_pre, revision: 2, physical_complete: true, continuation_state: :restored)
    end.to raise_error(ArgumentError, /application and physical completion/)
    expect do
      receipt(outcome: :confirmed_pre, revision: 2, application_state: :applied, continuation_state: :restored)
    end.to raise_error(ArgumentError, /application and physical completion/)
  end

  it "never exposes an execution observation before confirmed post-state continuation admission" do
    execution = Phronomy::TaskResult.completed
    expect { receipt(execution_task: execution) }.to raise_error(ArgumentError, /only resumed/)
    expect do
      receipt(outcome: :confirmed_post, revision: 3, physical_complete: true,
        application_state: :applied, execution_task: execution)
    end.to raise_error(ArgumentError, /only resumed/)
    expect do
      receipt(outcome: :confirmed_pre, revision: 2, physical_complete: true,
        application_state: :applied, continuation_state: :resumed, execution_task: execution)
    end.to raise_error(ArgumentError, /resumed approval requires confirmed post-state/)
    expect do
      receipt(outcome: :confirmed_post, revision: 3, physical_complete: true,
        application_state: :applied, continuation_state: :resumed)
    end.to raise_error(ArgumentError, /execution observation/)
    expect do
      receipt(outcome: :confirmed_post, revision: 3, physical_complete: true,
        application_state: :applied, continuation_state: :restored)
    end.to raise_error(ArgumentError, /only confirmed approval pre-state/)
  end
end

RSpec.describe Phronomy::Agent::ApprovalRecoveryApi do
  let(:agent) { Phronomy::Agent::Base.allocate }

  it "does not create a Runtime when looking up absent local responsibility" do
    expect(Phronomy::Runtime).not_to receive(:instance)
    expect(agent.pending_approval_recovery(execution_id: "execution-8")).to be_nil

    owner = double("installed owner", existing_registry: nil)
    agent.instance_variable_set(:@_phronomy_runtime_owner, owner)
    expect(agent.pending_approval_recovery(execution_id: "execution-8")).to be_nil
  end

  it "looks up the exact Agent incarnation in its existing registry" do
    capability = Object.new
    registry = double("existing registry")
    expect(registry).to receive(:pending_agent_approval_recovery)
      .with("execution-8", agent: agent).and_return(capability)
    owner = double("installed owner", existing_registry: registry)
    agent.instance_variable_set(:@_phronomy_runtime_owner, owner)

    expect(agent.pending_approval_recovery(execution_id: "execution-8")).to equal(capability)
  end

  it "rejects missing execution identities before local lookup" do
    [nil, "", :execution].each do |execution_id|
      expect { agent.pending_approval_recovery(execution_id: execution_id) }
        .to raise_error(ArgumentError, /nonempty String/)
    end
  end

  context "with a retained capability" do
    # The public wrapper needs operation identity and delegation. Real Runtime
    # custody, persistence and continuation execution have separate integration
    # coverage; this stand-in intentionally performs none of those operations.
    let(:operation_class) do
      Class.new do
        attr_accessor :agent_id, :execution_id, :approval_request_id, :recovery_id,
          :approved, :recovery, :owner

        def belongs_to?(candidate)
          owner.equal?(candidate)
        end

        def observe
          raise "the operation observation must be supplied by the example"
        end
      end
    end
    let(:operation) do
      stub_const("Phronomy::Agent::ApprovalRecoveryOperation", operation_class)
      operation_class.new.tap do |value|
        value.agent_id = "agent-7"
        value.execution_id = "execution-8"
        value.approval_request_id = "approval-9"
        value.recovery_id = "recovery-10"
        value.approved = true
        value.owner = agent
      end
    end
    let(:recovery) do
      Phronomy::Agent::ApprovalRecovery.send(:new, operation).tap { |value| operation.recovery = value }
    end

    it "delegates each asynchronous observation to the exact retained operation" do
      capability = recovery
      first = Phronomy::TaskResult.completed(:first)
      second = Phronomy::TaskResult.completed(:second)
      expect(operation).to receive(:observe).with(no_args).and_return(first, second)

      expect(agent.reconcile_approval_async(recovery: capability)).to equal(first)
      expect(agent.reconcile_approval_async(recovery: capability)).to equal(second)
    end

    it "unwraps the synchronous observation on a permitted host thread" do
      capability = recovery
      expect(operation).to receive(:observe).and_return(Phronomy::TaskResult.completed(:receipt))
      expect(agent.reconcile_approval(recovery: capability)).to eq(:receipt)
    end

    it "checks EventLoop reentrancy before starting an observation" do
      capability = recovery
      allow(Phronomy::WaitPolicy).to receive(:blocking_forbidden?).and_return(true)
      expect(operation).not_to receive(:observe)

      expect { agent.reconcile_approval(recovery: capability) }
        .to raise_error(Phronomy::EventLoopReentrancyError, /reconcile_approval_async/)
    end

    it "rejects a different Agent incarnation even with copied owner fields" do
      capability = recovery
      expect(operation).not_to receive(:observe)
      expect { agent.dup.reconcile_approval_async(recovery: capability) }
        .to raise_error(ArgumentError, /another Agent incarnation/)
    end

    it "rejects a copied capability that the operation did not issue" do
      capability = recovery.dup
      expect(operation).not_to receive(:observe)
      expect { agent.reconcile_approval_async(recovery: capability) }
        .to raise_error(ArgumentError, /another Agent incarnation/)
    end

    it "rejects a foreign operation behind a genuine capability class" do
      recovery
      foreign = double("foreign operation", agent_id: "agent-7", execution_id: "execution-8",
        approval_request_id: "approval-9", recovery_id: "recovery-10", approved: true)
      capability = Phronomy::Agent::ApprovalRecovery.send(:new, foreign)
      expect { agent.reconcile_approval_async(recovery: capability) }
        .to raise_error(ArgumentError, /another Agent incarnation/)
    end

    it "rejects value lookalikes before consulting an operation" do
      expect { agent.reconcile_approval_async(recovery: Object.new) }
        .to raise_error(ArgumentError, /must be an Agent::ApprovalRecovery/)
    end
  end
end
