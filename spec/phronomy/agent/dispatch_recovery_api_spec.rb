# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent dispatch recovery observation contracts" do
  let(:identities) do
    {agent_id: +"agent-7", execution_id: +"execution-8",
     recovery_id: +"recovery-9", dispatch_kind: :provider}
  end
  let(:operation) { double("retained dispatch operation", **identities) }
  let(:recovery) { Phronomy::Agent::DispatchRecovery.send(:new, operation) }
  let(:pending_values) do
    {recovery: recovery, outcome: :unresolved, application_state: :pending,
     continuation_state: :pending, physical_complete: false}
  end

  def receipt(**changes)
    Phronomy::Agent::DispatchRecoveryResult.new(**pending_values.merge(changes))
  end

  it "keeps authority private while snapshotting diagnostic identities" do
    capability = recovery
    expect { Phronomy::Agent::DispatchRecovery.new(operation) }.to raise_error(NoMethodError, /private method/)
    expect(capability).to be_frozen
    expect(capability).not_to respond_to(:operation)
    expect(capability.send(:operation)).to equal(operation)
    expect(capability.dispatch_kind).to eq(:provider)
    identities.each do |name, original|
      next unless original.is_a?(String)
      expected = original.dup
      original.replace("changed identity")
      expect(capability.public_send(name)).to eq(expected)
      expect(capability.public_send(name)).to be_frozen
    end
  end

  it "delivers the retained reference and separates original failure from observation cause" do
    original = IOError.new("dispatch save response lost")
    current = IOError.new("dispatch read unavailable")
    error = Phronomy::Agent::DispatchRecoveryError.new(
      recovery: recovery, error: current, original_error: original
    )
    expect { Phronomy::TaskResult.failed(error).wait_result }.to raise_error do |delivered|
      expect(delivered).to equal(error)
      expect(delivered.code).to eq("agent.dispatch_recovery")
      expect(delivered.recovery).to equal(recovery)
      expect(delivered.original_error).to equal(original)
      expect(delivered.cause).to equal(current)
      expect(delivered.dispatch_kind).to eq(:provider)
      expect(delivered).not_to be_a(Phronomy::CancellationError)
    end
    expect(Phronomy::Error.diagnostic(error).fetch("cause").fetch("message"))
      .to eq("dispatch read unavailable")
  end

  it "defaults the original cause to the first operation failure" do
    failure = IOError.new("dispatch preparation uncertain")
    error = Phronomy::Agent::DispatchRecoveryError.new(recovery: recovery, error: failure)
    expect(error.original_error).to equal(failure)
    expect(error.cause).to equal(failure)
  end

  it "retains confirmed pre-state for an explicit persistence-only retry" do
    value = receipt(outcome: :confirmed_pre, revision: 0, physical_complete: true)
    expect(value).to be_frozen
    expect(value.revision).to eq(0)
    expect(value.resolved?).to be(false)
    expect(value.application_state).to eq(:pending)
    expect(value.continuation_state).to eq(:pending)
    expect(value.execution_task).to be_nil
  end

  it "retains positively unprepared work while its failure notification is pending" do
    failure = IOError.new("setup-failure notification rejected")
    initial = receipt(outcome: :not_prepared, physical_complete: true, error: failure)
    adopted = receipt(outcome: :not_prepared, physical_complete: true,
      application_state: :applied, error: failure)
    [initial, adopted].each do |value|
      expect(value.revision).to be_nil
      expect(value.resolved?).to be(false)
      expect(value.continuation_state).to eq(:pending)
      expect(value.execution_task).to be_nil
      expect(value.error).to equal(failure)
    end
  end

  it "resolves positively unprepared work by handing off only its stopped continuation" do
    failure = IOError.new("input hook failed before the barrier")
    execution = Phronomy::TaskResult.deferred
    value = receipt(outcome: :not_prepared, physical_complete: true,
      application_state: :applied, continuation_state: :stopped, execution_task: execution)
    expect(value.resolved?).to be(true)
    expect(value.physical_complete?).to be(true)
    expect(value.revision).to be_nil
    expect(value.error).to be_nil
    expect(execution.done?).to be(false)
    execution.fail(failure)
    expect { value.execution_task.wait_result }.to raise_error { |actual| expect(actual).to equal(failure) }
  end

  it "never represents a missing barrier as a confirmed revision or resumed dispatch" do
    expect { receipt(outcome: :not_prepared, revision: 3) }
      .to raise_error(ArgumentError, /no confirmed revision/)
    expect { receipt(outcome: :not_prepared, continuation_state: :resumed) }
      .to raise_error(ArgumentError, /cannot resume a barrier/)
    expect { receipt(outcome: :confirmed_post, revision: 3, continuation_state: :stopped) }
      .to raise_error(ArgumentError, /only positively unprepared/)
  end

  it "requires applied state, physical completion and an independent observer for stopped" do
    execution = Phronomy::TaskResult.failed(IOError.new("setup failed"))
    values = {outcome: :not_prepared, application_state: :applied, physical_complete: true,
              continuation_state: :stopped, execution_task: execution}
    [{application_state: :pending}, {physical_complete: false}, {execution_task: nil}].each do |change|
      expect { receipt(**values.merge(change)) }.to raise_error(ArgumentError, /requires application/)
    end
    expect { receipt(outcome: :not_prepared, execution_task: execution) }
      .to raise_error(ArgumentError, /only resumed or stopped/)
  end

  it "does not treat a confirmed barrier as continuation or physical completion" do
    value = receipt(outcome: :confirmed_post, revision: 3)
    expect(value.resolved?).to be(false)
    expect(value.physical_complete?).to be(false)
    expect(value.execution_task).to be_nil
  end

  it "records applied post-state while continuation remains pending" do
    failure = RuntimeError.new("continuation registration unavailable")
    value = receipt(outcome: :confirmed_post, revision: 3, physical_complete: true,
      application_state: :applied, error: failure)
    expect(value.resolved?).to be(false)
    expect(value.execution_task).to be_nil
    expect(value.error).to equal(failure)
  end

  it "resolves the barrier while the continued job is still active" do
    execution = Phronomy::TaskResult.deferred
    value = receipt(outcome: :confirmed_post, revision: 3, physical_complete: true,
      application_state: :applied, continuation_state: :resumed, execution_task: execution)
    expect(value.resolved?).to be(true)
    expect(value.physical_complete?).to be(true)
    expect(value.execution_task).to equal(execution)
    expect(execution.status).to eq(:pending)
    expect(value).not_to respond_to(:ownership_state)
  end

  it "keeps a failed or cancelled continuation separate from barrier resolution" do
    [IOError.new("input materialization failed"), Phronomy::CancellationError.new("cancelled before dispatch")].each do |failure|
      execution = Phronomy::TaskResult.failed(failure)
      value = receipt(outcome: :confirmed_post, revision: 3, physical_complete: true,
        application_state: :applied, continuation_state: :resumed, execution_task: execution)
      expect(value.resolved?).to be(true)
      expect(value.error).to be_nil
      expect { value.execution_task.wait_result }.to raise_error { |actual| expect(actual).to equal(failure) }
    end
  end

  it "rejects invalid state domains and nonboolean physical completion" do
    [{outcome: :unknown}, {application_state: :done}, {continuation_state: :restored}].each do |changes|
      expect { receipt(**changes) }.to raise_error(ArgumentError, /unsupported/)
    end
    [nil, 0, :complete].each do |value|
      expect { receipt(physical_complete: value) }.to raise_error(ArgumentError, /boolean/)
    end
  end

  it "requires an actual revision for confirmed persistence and none for unavailable proof" do
    [nil, -1, "3"].each do |revision|
      %i[confirmed_pre confirmed_post].each do |outcome|
        expect { receipt(outcome: outcome, revision: revision) }.to raise_error(ArgumentError, /nonnegative/)
      end
    end
    expect { receipt(outcome: :unavailable, revision: 3) }.to raise_error(ArgumentError, /unclassified/)
  end

  it "cannot apply or resume unconfirmed or confirmed pre-state work" do
    %i[unresolved unavailable confirmed_pre].each do |outcome|
      revision = (outcome == :confirmed_pre) ? 2 : nil
      expect { receipt(outcome: outcome, revision: revision, application_state: :applied) }
        .to raise_error(ArgumentError, /without confirmed post-state/)
      expect { receipt(outcome: outcome, revision: revision, continuation_state: :resumed) }
        .to raise_error(ArgumentError, /without confirmed post-state/)
    end
  end

  it "requires application, physical completion and an execution observer before resumed" do
    task = Phronomy::TaskResult.completed(:done)
    values = {outcome: :confirmed_post, revision: 3, physical_complete: true,
              application_state: :applied, continuation_state: :resumed, execution_task: task}
    [{physical_complete: false}, {application_state: :pending}, {execution_task: nil}].each do |change|
      expect { receipt(**values.merge(change)) }.to raise_error(ArgumentError, /requires application/)
    end
    expect { receipt(execution_task: task) }.to raise_error(ArgumentError, /only resumed/)
  end
end

RSpec.describe Phronomy::Agent::DispatchRecoveryApi do
  let(:agent) { Phronomy::Agent::Base.allocate }

  it "does not construct a Runtime to look up an absent local obligation" do
    expect(Phronomy::Runtime).not_to receive(:instance)
    expect(agent.pending_dispatch_recovery(execution_id: "execution-8")).to be_nil
    agent.instance_variable_set(:@_phronomy_runtime_owner, double("owner", existing_registry: nil))
    expect(agent.pending_dispatch_recovery(execution_id: "execution-8")).to be_nil
  end

  it "looks up the exact Agent incarnation in the existing registry" do
    capability = Object.new
    registry = double("registry")
    expect(registry).to receive(:pending_agent_dispatch_recovery).with("execution-8", agent: agent).and_return(capability)
    agent.instance_variable_set(:@_phronomy_runtime_owner, double("owner", existing_registry: registry))
    expect(agent.pending_dispatch_recovery(execution_id: "execution-8")).to equal(capability)
  end

  it "rejects invalid execution identifiers before any lookup" do
    [nil, "", :execution].each do |execution_id|
      expect { agent.pending_dispatch_recovery(execution_id: execution_id) }.to raise_error(ArgumentError, /nonempty String/)
    end
  end

  context "with a retained capability" do
    # This stand-in isolates identity validation and API delegation. Real
    # persistence, Runtime custody and continuation have separate fault tests.
    let(:operation_class) do
      Class.new do
        attr_accessor :agent_id, :execution_id, :recovery_id, :dispatch_kind, :recovery, :owner

        def belongs_to?(candidate)
          owner.equal?(candidate)
        end

        def observe(_mode)
          raise "the observation must be supplied by the example"
        end
      end
    end
    let(:operation) do
      stub_const("Phronomy::Agent::DispatchRecoveryOperation", operation_class)
      operation_class.new.tap do |value|
        value.agent_id = "agent-7"
        value.execution_id = "execution-8"
        value.recovery_id = "recovery-9"
        value.dispatch_kind = :tool
        value.owner = agent
      end
    end
    let(:recovery) do
      Phronomy::Agent::DispatchRecovery.send(:new, operation).tap { |value| operation.recovery = value }
    end

    %i[reconcile retry].each do |mode|
      it "delegates fresh asynchronous #{mode} observations to the exact operation" do
        capability = recovery
        first = Phronomy::TaskResult.completed(:first)
        second = Phronomy::TaskResult.completed(:second)
        expect(operation).to receive(:observe).with(mode).and_return(first, second)
        expect(agent.public_send("#{mode}_dispatch_async", recovery: capability)).to equal(first)
        expect(agent.public_send("#{mode}_dispatch_async", recovery: capability)).to equal(second)
      end

      it "unwraps synchronous #{mode} on a permitted host thread" do
        capability = recovery
        expect(operation).to receive(:observe).with(mode).and_return(Phronomy::TaskResult.completed(:receipt))
        expect(agent.public_send("#{mode}_dispatch", recovery: capability)).to eq(:receipt)
      end

      it "checks EventLoop reentrancy before starting #{mode}" do
        capability = recovery
        allow(Phronomy::WaitPolicy).to receive(:blocking_forbidden?).and_return(true)
        expect(operation).not_to receive(:observe)
        expect { agent.public_send("#{mode}_dispatch", recovery: capability) }
          .to raise_error(Phronomy::EventLoopReentrancyError, /#{mode}_dispatch_async/)
      end

      it "rejects another Agent incarnation for #{mode}" do
        capability = recovery
        expect(operation).not_to receive(:observe)
        expect { agent.dup.public_send("#{mode}_dispatch_async", recovery: capability) }
          .to raise_error(ArgumentError, /another Agent incarnation/)
      end

      it "rejects a copied capability for #{mode}" do
        capability = recovery.dup
        expect(operation).not_to receive(:observe)
        expect { agent.public_send("#{mode}_dispatch_async", recovery: capability) }
          .to raise_error(ArgumentError, /another Agent incarnation/)
      end

      it "rejects value lookalikes for #{mode}" do
        expect { agent.public_send("#{mode}_dispatch_async", recovery: Object.new) }
          .to raise_error(ArgumentError, /must be an Agent::DispatchRecovery/)
      end
    end

    it "rejects foreign operations behind a genuine capability class" do
      recovery
      foreign = double("foreign operation", agent_id: "agent-7", execution_id: "execution-8",
        recovery_id: "recovery-9", dispatch_kind: :tool)
      capability = Phronomy::Agent::DispatchRecovery.send(:new, foreign)
      expect { agent.reconcile_dispatch_async(recovery: capability) }
        .to raise_error(ArgumentError, /another Agent incarnation/)
    end
  end
end
