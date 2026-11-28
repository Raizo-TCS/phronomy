# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent initial preparation recovery observation contracts" do
  let(:identities) { {agent_id: +"agent-7", execution_id: +"execution-8", recovery_id: +"recovery-9"} }
  let(:operation) { double("retained initial preparation", **identities) }
  let(:recovery) { Phronomy::Agent::InitialPreparationRecovery.send(:new, operation) }
  let(:pending_values) do
    {recovery: recovery, stage: :admission, outcome: :unresolved,
     application_state: :pending, continuation_state: :pending, physical_complete: false}
  end

  def receipt(**changes)
    Phronomy::Agent::InitialPreparationRecoveryResult.new(**pending_values.merge(changes))
  end

  it "keeps owner authority private and snapshots nonempty diagnostic identities" do
    capability = recovery
    expect { Phronomy::Agent::InitialPreparationRecovery.new(operation) }.to raise_error(NoMethodError, /private method/)
    expect(capability).to be_frozen
    expect(capability).not_to respond_to(:operation)
    expect(capability.send(:operation)).to equal(operation)
    identities.each do |name, original|
      expected = original.dup
      original.replace("changed identity")
      expect(capability.public_send(name)).to eq(expected)
      expect(capability.public_send(name)).to be_frozen
    end
    allow(operation).to receive(:execution_id).and_return("")
    expect { Phronomy::Agent::InitialPreparationRecovery.send(:new, operation) }
      .to raise_error(ArgumentError, /must not be empty/)
  end

  it "preserves the retained reference and separates original failure from recovery cause" do
    original = IOError.new("initial save response lost")
    current = IOError.new("initial read unavailable")
    error = Phronomy::Agent::InitialPreparationRecoveryError.new(
      recovery: recovery, error: current, original_error: original
    )
    expect { Phronomy::TaskResult.failed(error).wait_result }.to raise_error do |delivered|
      expect(delivered).to equal(error)
      expect(delivered.code).to eq("agent.initial_preparation_recovery")
      expect(delivered.recovery).to equal(recovery)
      expect(delivered.original_error).to equal(original)
      expect(delivered.cause).to equal(current)
      expect(delivered).not_to be_a(Phronomy::CancellationError)
    end
    expect(Phronomy::Error.diagnostic(error).fetch("cause").fetch("message"))
      .to eq("initial read unavailable")
    initial = Phronomy::Agent::InitialPreparationRecoveryError.new(recovery: recovery, error: original)
    expect(initial.original_error).to equal(original)
    expect(initial.cause).to equal(original)
  end

  it "rejects non-capabilities and non-exception diagnostic causes" do
    expect { receipt(recovery: Object.new) }.to raise_error(ArgumentError, /InitialPreparationRecovery/)
    expect { receipt(error: "failure") }.to raise_error(ArgumentError, /exception/)
    expect { Phronomy::Agent::InitialPreparationRecoveryError.new(recovery: Object.new, error: nil) }
      .to raise_error(ArgumentError, /InitialPreparationRecovery/)
    [{error: "failure"}, {error: nil, original_error: "failure"}].each do |causes|
      expect { Phronomy::Agent::InitialPreparationRecoveryError.new(recovery: recovery, **causes) }
        .to raise_error(ArgumentError, /exceptions/)
    end
  end

  it "keeps confirmed admission distinct from activation and continuation" do
    %i[confirmed_pre confirmed_post].each do |outcome|
      value = receipt(outcome: outcome, revision: 0, physical_complete: true)
      expect(value).to be_frozen
      expect(value.stage).to eq(:admission)
      expect(value.revision).to eq(0)
      expect(value.resolved?).to be(false)
      expect(value.execution_task).to be_nil
      expect { receipt(outcome: outcome, revision: 1) }.to raise_error(ArgumentError, /revision zero/)
    end
    expect { receipt(outcome: :confirmed_post, revision: 0, continuation_state: :resumed) }
      .to raise_error(ArgumentError, /contradicts/)
  end

  it "reports the previous revision before activation or failure and an advanced revision afterwards" do
    %i[activation failure].each do |stage|
      expect(receipt(stage: stage, outcome: :confirmed_pre, revision: 0).revision).to eq(0)
      expect(receipt(stage: stage, outcome: :confirmed_pre, revision: 2).revision).to eq(2)
      expect(receipt(stage: stage, outcome: :confirmed_post, revision: 3).revision).to eq(3)
      expect { receipt(stage: stage, outcome: :confirmed_post, revision: 0) }
        .to raise_error(ArgumentError, /advanced execution revision/)
    end
  end

  it "keeps historical post-state while current authority or handover is unavailable" do
    failure = Phronomy::CancellationError.new("cancelled before continuation")
    value = receipt(stage: :activation, outcome: :confirmed_post, revision: 1,
      physical_complete: true, error: failure)
    expect(value.resolved?).to be(false)
    expect(value.application_state).to eq(:pending)
    expect(value.error).to equal(failure)
    expect(value.execution_task).to be_nil
    applied = receipt(stage: :activation, outcome: :confirmed_post, revision: 1,
      physical_complete: true, application_state: :applied, error: IOError.new("handover unavailable"))
    expect(applied.resolved?).to be(false)
  end

  it "resolves activation while its fresh exact-execution observation is still pending" do
    task = Phronomy::TaskResult.deferred
    value = receipt(stage: :activation, outcome: :confirmed_post, revision: 1,
      physical_complete: true, application_state: :applied, continuation_state: :resumed, execution_task: task)
    expect(value.resolved?).to be(true)
    expect(value.physical_complete?).to be(true)
    expect(value.execution_task).to equal(task)
    expect(task.done?).to be(false)
  end

  it "resolves saved failure with a fulfilled saved-status observation" do
    saved = {status: :failed, error: "hook rejected initial input"}
    task = Phronomy::TaskResult.completed(saved)
    value = receipt(stage: :failure, outcome: :confirmed_post, revision: 1,
      physical_complete: true, application_state: :applied, continuation_state: :stopped, execution_task: task)
    expect(value.resolved?).to be(true)
    expect(value.error).to be_nil
    expect(value.execution_task.wait_result).to equal(saved)
    expect { receipt(stage: :failure, outcome: :confirmed_post, revision: 1, continuation_state: :resumed) }
      .to raise_error(ArgumentError, /contradicts/)
    expect { receipt(stage: :activation, outcome: :confirmed_post, revision: 1, continuation_state: :stopped) }
      .to raise_error(ArgumentError, /contradicts/)
  end

  it "stops cancelled admission at proven absence without claiming the proposal was unprepared" do
    failure = Phronomy::CancellationError.new("cancelled before admission")
    task = Phronomy::TaskResult.failed(failure)
    value = receipt(outcome: :confirmed_pre, revision: 0, physical_complete: true,
      application_state: :applied, continuation_state: :stopped, execution_task: task)
    expect(value.resolved?).to be(true)
    expect(value.outcome).to eq(:confirmed_pre)
    expect(value.revision).to eq(0)
    expect { value.execution_task.wait_result }.to raise_error { |actual| expect(actual).to equal(failure) }
    %i[activation failure].each do |stage|
      expect { receipt(stage: stage, outcome: :confirmed_pre, revision: 0, continuation_state: :stopped) }
        .to raise_error(ArgumentError, /must remain pending/)
    end
  end

  it "stops positively unprepared admission with no revision and a failed fresh observation" do
    failure = IOError.new("input capture failed")
    task = Phronomy::TaskResult.failed(failure)
    value = receipt(outcome: :not_prepared, physical_complete: true,
      application_state: :applied, continuation_state: :stopped, execution_task: task)
    expect(value.resolved?).to be(true)
    expect(value.revision).to be_nil
    expect { value.execution_task.wait_result }.to raise_error { |actual| expect(actual).to equal(failure) }
    expect { receipt(outcome: :not_prepared, stage: :activation) }.to raise_error(ArgumentError, /only initial admission/)
    expect { receipt(outcome: :not_prepared, continuation_state: :resumed) }.to raise_error(ArgumentError, /contradicts/)
  end

  it "requires application, physical completion and an observer for each legal continuation" do
    task = Phronomy::TaskResult.completed({status: :failed})
    [[:activation, :confirmed_post, 1, :resumed], [:failure, :confirmed_post, 1, :stopped],
      [:admission, :confirmed_pre, 0, :stopped], [:admission, :not_prepared, nil, :stopped]].each do |stage, outcome, revision, continuation|
      values = {stage: stage, outcome: outcome, revision: revision, physical_complete: true,
                application_state: :applied, continuation_state: continuation, execution_task: task}
      [{application_state: :pending}, {physical_complete: false}, {execution_task: nil}, {execution_task: Object.new}].each do |change|
        expect { receipt(**values.merge(change)) }.to raise_error(ArgumentError, /requires application/)
      end
    end
    expect { receipt(execution_task: task) }.to raise_error(ArgumentError, /only resumed or stopped/)
  end

  it "rejects invalid state domains, revisions and false claims of application" do
    [{stage: :dispatch}, {outcome: :unknown}, {application_state: :done}, {continuation_state: :restored}].each do |change|
      expect { receipt(**change) }.to raise_error(ArgumentError, /unsupported/)
    end
    [nil, 0, :complete].each do |value|
      expect { receipt(physical_complete: value) }.to raise_error(ArgumentError, /boolean/)
    end
    [nil, -1, "0"].each do |revision|
      %i[confirmed_pre confirmed_post].each do |outcome|
        expect { receipt(outcome: outcome, revision: revision) }.to raise_error(ArgumentError, /nonnegative/)
      end
    end
    %i[unresolved unavailable not_prepared].each do |outcome|
      expect { receipt(outcome: outcome, revision: 0) }.to raise_error(ArgumentError, /no confirmed revision/)
    end
    %i[unresolved unavailable confirmed_pre].each do |outcome|
      revision = (outcome == :confirmed_pre) ? 0 : nil
      expect { receipt(outcome: outcome, revision: revision, application_state: :applied) }
        .to raise_error(ArgumentError, /must remain pending/)
    end
  end
end

RSpec.describe Phronomy::Agent::InitialPreparationRecoveryApi do
  let(:agent) { Phronomy::Agent::Base.allocate }

  it "looks up an absent local obligation without creating a Runtime" do
    expect(Phronomy::Runtime).not_to receive(:instance)
    expect(agent.pending_initial_preparation_recovery).to be_nil
    agent.instance_variable_set(:@_phronomy_runtime_owner, double("owner", existing_registry: nil))
    expect(agent.pending_initial_preparation_recovery).to be_nil
  end

  it "looks up the exact Agent without requiring a durably admitted execution identifier" do
    capability = Object.new
    registry = double("registry")
    expect(registry).to receive(:pending_initial_preparation_recovery).with(agent: agent).and_return(capability)
    agent.instance_variable_set(:@_phronomy_runtime_owner, double("owner", existing_registry: registry))
    expect(agent.pending_initial_preparation_recovery).to equal(capability)
  end

  context "with a retained capability" do
    # This stand-in isolates identity checks and delegation. Fault-injection
    # application examples exercise actual persistence and continuation.
    let(:operation_class) do
      Class.new do
        attr_accessor :agent_id, :execution_id, :recovery_id, :recovery, :owner

        def belongs_to?(candidate)
          owner.equal?(candidate)
        end

        def observe(_mode)
          raise "the observation must be supplied by the example"
        end
      end
    end
    let(:operation) do
      stub_const("Phronomy::Agent::InitialPreparationRecoveryOperation", operation_class)
      operation_class.new.tap do |value|
        value.agent_id = "agent-7"
        value.execution_id = "execution-8"
        value.recovery_id = "recovery-9"
        value.owner = agent
      end
    end
    let(:recovery) do
      Phronomy::Agent::InitialPreparationRecovery.send(:new, operation).tap { |value| operation.recovery = value }
    end

    %i[reconcile retry].each do |mode|
      it "delegates fresh asynchronous #{mode} observations to the exact owner" do
        capability = recovery
        first = Phronomy::TaskResult.completed(:first)
        second = Phronomy::TaskResult.completed(:second)
        expect(operation).to receive(:observe).with(mode).and_return(first, second)
        expect(agent.public_send("#{mode}_initial_preparation_async", recovery: capability)).to equal(first)
        expect(agent.public_send("#{mode}_initial_preparation_async", recovery: capability)).to equal(second)
      end

      it "waits for synchronous #{mode} on a host thread" do
        capability = recovery
        expect(operation).to receive(:observe).with(mode).and_return(Phronomy::TaskResult.completed(:receipt))
        expect(agent.public_send("#{mode}_initial_preparation", recovery: capability)).to eq(:receipt)
      end

      it "rejects EventLoop blocking before starting #{mode}" do
        capability = recovery
        allow(Phronomy::WaitPolicy).to receive(:blocking_forbidden?).and_return(true)
        expect(operation).not_to receive(:observe)
        expect { agent.public_send("#{mode}_initial_preparation", recovery: capability) }
          .to raise_error(Phronomy::EventLoopReentrancyError, /#{mode}_initial_preparation_async/)
      end

      it "rejects another Agent incarnation, copied capabilities and lookalikes for #{mode}" do
        capability = recovery
        expect(operation).not_to receive(:observe)
        expect { agent.dup.public_send("#{mode}_initial_preparation_async", recovery: capability) }
          .to raise_error(ArgumentError, /another Agent incarnation/)
        expect { agent.public_send("#{mode}_initial_preparation_async", recovery: capability.dup) }
          .to raise_error(ArgumentError, /another Agent incarnation/)
        expect { agent.public_send("#{mode}_initial_preparation_async", recovery: Object.new) }
          .to raise_error(ArgumentError, /InitialPreparationRecovery/)
      end
    end

    it "rejects foreign operation authority behind a genuine capability type" do
      recovery
      foreign = double("foreign operation", agent_id: "agent-7", execution_id: "execution-8", recovery_id: "recovery-9")
      capability = Phronomy::Agent::InitialPreparationRecovery.send(:new, foreign)
      expect { agent.reconcile_initial_preparation_async(recovery: capability) }
        .to raise_error(ArgumentError, /another Agent incarnation/)
    end
  end
end
