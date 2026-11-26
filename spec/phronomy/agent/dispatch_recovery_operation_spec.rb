# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::DispatchRecoveryOperation do
  let(:persistence) { Object.new }
  let(:agent) { double("agent", agent_id: "dispatch-agent", persistence: persistence) }
  let(:command) do
    execution = Struct.new(:metadata).new({}.freeze)
    Struct.new(:execution_id, :fsm_session_id, :expected_execution_revision, :execution)
      .new("execution-1", "session-1", 3, execution)
  end
  let(:invocation) { Object.new }
  let(:registry) do
    Class.new do
      attr_accessor :owner, :reject_ready, :accept_owner
      attr_reader :messages

      def initialize
        @messages = []
        @accept_owner = true
      end

      def retain_dispatch_operation(value)
        @owner = value
      end

      def owns_dispatch_operation?(value)
        @accept_owner && @owner.equal?(value)
      end

      def resolve_dispatch_operation(value)
        return false unless owns_dispatch_operation?(value) && value.resolution_permitted?
        @owner = nil
        value.resolution_released!
        true
      end

      def post(value, completion: nil)
        return false if @reject_ready && value.is_a?(Phronomy::Agent::DispatchRecoveryOperation::Ready)
        @messages << value
        true
      end
    end.new
  end
  let(:environment) { double("environment", registry: registry) }
  let(:coordinator) { double("coordinator") }
  let(:preparer) { double("dispatch preparer") }
  let(:evidence) { double("complete dispatch evidence") }
  let(:original) { Phronomy::TaskResult.deferred(name: "original-dispatch-observer") }
  let(:outcome) do
    Struct.new(:execution).new(Struct.new(:execution_revision).new(4))
  end
  let(:operation) do
    described_class.new(agent: agent, coordinator: coordinator, environment: environment,
      command: command, invocation: invocation, dispatch_kind: :provider,
      preparer: preparer, original_waiters: [original])
  end

  def proof(disposition, error = nil)
    Struct.new(:disposition, :read_error).new(disposition, error)
  end

  def drain
    until registry.messages.empty?
      message = registry.messages.shift
      message.operation.deliver(message)
    end
  end

  def complete_worker(index, physical: true)
    task, work = @submitted.fetch(index)
    begin
      task.complete(work.call)
    rescue => error
      task.fail(error)
    ensure
      task.mark_physical_complete! if physical
    end
    drain
    task
  end

  def start_unknown
    allow(preparer).to receive(:prepare_provider) do |_command, on_evidence:, on_outcome:, on_barrier_started:|
      on_barrier_started.call
      on_evidence.call(evidence)
      raise Phronomy::ExecutionRehydrationRequiredError, "dispatch write outcome unknown"
    end
    operation.start
    complete_worker(0)
    expect(original.__snapshot.last).to be_a(Phronomy::Agent::DispatchRecoveryError)
    expect(operation.pending?).to be(true)
  end

  before do
    @submitted, @applied, @stopped = [], [], []
    allow(Phronomy::Execution).to receive(:submit_with_rejection_evidence) do |_environment, **_options, &work|
      Phronomy::Concurrency::PhysicalCompletionTask.deferred.tap { |task| @submitted << [task, work] }
    end
    allow(coordinator).to receive(:dispatch_recovery_failed_on_event_loop)
    allow(coordinator).to receive(:apply_retained_dispatch_on_event_loop) do |owner, result|
      @applied << result
      owner.prepare_continuation
      owner.application_applied!
      raise "continuation replay" unless owner.authorize_continuation!
      owner.continuation_completed!
    end
    allow(coordinator).to receive(:stop_retained_dispatch_on_event_loop) do |owner, error|
      @stopped << error
      owner.prepare_failed_continuation!
      owner.prepare_continuation
      owner.application_applied!
      owner.authorize_continuation!
      owner.continuation_returned!
      owner.continuation_completed!(:stopped)
    end
    allow(preparer).to receive(:recover_result).with(evidence).and_return(outcome)
  end

  it "preserves a cancelled recovery observation while a shared read later resumes the original execution" do
    start_unknown
    original_error = original.__snapshot.last
    allow(evidence).to receive(:reconcile).and_return(proof(:committed))
    abandoned = operation.observe
    drain
    abandoned.cancel!
    current = operation.observe
    drain
    expect(@submitted.size).to eq(2)

    complete_worker(1)
    receipt = current.wait_result
    expect(receipt.resolved?).to be(true)
    expect(receipt.execution_task.status).to eq(:pending)
    expect(abandoned.status).to eq(:cancelled)
    expect(original.__snapshot.last).to equal(original_error)
    expect(@applied).to eq([outcome])
    expect(registry.owner).to be_nil
    expect(operation.agent).to be_nil
    expect(operation.invocation).to be_nil

    operation.continuation_task.complete(:later_result)
    expect(receipt.execution_task.wait_result).to eq(:later_result)
    repeated = operation.observe.wait_result
    expect(repeated.execution_task).not_to equal(receipt.execution_task)
    expect(repeated.execution_task.wait_result).to eq(:later_result)
    expect(@applied.size).to eq(1)
  end

  it "does not report an earlier confirmed pre-state after an ambiguous captured-write retry" do
    start_unknown
    allow(evidence).to receive(:reconcile).and_return(proof(:not_committed))
    before = operation.observe
    drain
    complete_worker(1)
    expect(before.wait_result.outcome).to eq(:confirmed_pre)
    expect(before.wait_result.revision).to eq(3)

    read_error = IOError.new("retry read unavailable")
    allow(evidence).to receive(:retry).and_return(proof(:unknown, read_error))
    retried = operation.observe(:retry)
    drain
    complete_worker(2)
    receipt = retried.wait_result
    expect(receipt.outcome).to eq(:unavailable)
    expect(receipt.revision).to be_nil
    expect(receipt.error.cause).to equal(read_error)
    expect(receipt.resolved?).to be(false)
    expect(@applied).to be_empty
    expect(registry.owner).to equal(operation)
  end

  it "keeps one physical lane when a different recovery mode races an active read" do
    start_unknown
    allow(evidence).to receive(:reconcile).and_return(proof(:not_committed))
    first = operation.observe
    drain
    concurrent_retry = operation.observe(:retry)
    drain
    expect(concurrent_retry.wait_result.outcome).to eq(:unavailable)
    expect(@submitted.size).to eq(2)
    first.cancel!
    next_reader = operation.observe
    drain
    expect(@submitted.size).to eq(2)
    complete_worker(1)
    expect(next_reader.wait_result.outcome).to eq(:confirmed_pre)
    expect(first.status).to eq(:cancelled)
  end

  it "does not infer physical completion from a lost initial submission handle" do
    hidden_work = nil
    allow(preparer).to receive(:prepare_provider).and_return(outcome)
    allow(Phronomy::Execution).to receive(:submit_with_rejection_evidence) do |_environment, **_options, &work|
      hidden_work = work
      raise IOError, "submission reply lost"
    end
    operation.start
    drain
    hidden_work.call
    observation = operation.observe
    drain

    expect(observation.wait_result.outcome).to eq(:unavailable)
    expect(observation.wait_result.physical_complete?).to be(false)
    expect(@applied).to be_empty
    expect(registry.owner).to equal(operation)
  end

  it "retains a successful worker result when its Ready delivery is rejected" do
    registry.reject_ready = true
    allow(preparer).to receive(:prepare_provider).and_return(outcome)
    operation.start
    complete_worker(0)
    expect(original.__snapshot.last).to be_a(Phronomy::Agent::DispatchRecoveryError)
    expect(@applied).to be_empty
    registry.reject_ready = false
    observation = operation.observe
    drain

    expect(observation.wait_result.resolved?).to be(true)
    expect(@submitted.size).to eq(1)
    expect(@applied).to eq([outcome])
  end

  it "polls a retained handle after completion-subscription failure without starting another worker" do
    allow(preparer).to receive(:prepare_provider).and_return(outcome)
    allow(Phronomy::Execution).to receive(:submit_with_rejection_evidence) do |_environment, **_options, &work|
      Phronomy::Concurrency::PhysicalCompletionTask.deferred.tap do |task|
        @submitted << [task, work]
        allow(task).to receive(:on_complete).and_raise(IOError, "subscription failed")
      end
    end
    operation.start
    complete_worker(0)
    observation = operation.observe
    drain
    expect(observation.wait_result.resolved?).to be(true)
    expect(@submitted.size).to eq(1)
    expect(@applied).to eq([outcome])
  end

  it "does not release the original job's physical lease when its observation fails" do
    finished = false
    original.define_singleton_method(:finish_operation!) { finished = true }
    start_unknown
    expect(finished).to be(false)
    operation.shutdown(Phronomy::RuntimeShutdownError.new("stopped"))
    expect(finished).to be(false)
    expect(operation.pending?).to be(true)
  end

  it "ignores a stale completed-attempt message after a newer read owns the lane" do
    start_unknown
    allow(evidence).to receive(:reconcile).and_return(proof(:not_committed), proof(:committed))
    first = operation.observe
    drain
    old_id = operation.instance_variable_get(:@attempt).fetch(:id)
    complete_worker(1)
    expect(first.wait_result.outcome).to eq(:confirmed_pre)
    current = operation.observe
    drain
    operation.deliver(described_class::Ready.new(operation: operation, attempt_id: old_id))
    expect(current.status).to eq(:pending)
    expect(@applied).to be_empty
    complete_worker(2)
    expect(current.wait_result.resolved?).to be(true)
    expect(@applied).to eq([outcome])
  end

  it "routes an ordinary pre-proposal failure to the original setup-failed transition" do
    error = ArgumentError.new("invalid Provider input")
    allow(preparer).to receive(:prepare_provider).and_raise(error)
    operation.start
    complete_worker(0)
    expect(@stopped).to eq([error])
    expect(original.status).to eq(:pending)
    expect(registry.owner).to be_nil
    expect(operation.pending?).to be(false)
    expect(@applied).to be_empty
    receipt = operation.observe.wait_result
    expect(receipt.outcome).to eq(:not_prepared)
    expect(receipt.continuation_state).to eq(:stopped)
    expect(receipt.resolved?).to be(true)
    expect(receipt.revision).to be_nil
    expect(receipt.execution_task.status).to eq(:pending)
  end

  it "can hand a retained early failure onward after its original Ready delivery was rejected" do
    registry.reject_ready = true
    error = ArgumentError.new("input preparation failed before the barrier")
    allow(preparer).to receive(:prepare_provider).and_raise(error)
    operation.start
    complete_worker(0)
    expect(original.__snapshot.last).to be_a(Phronomy::Agent::DispatchRecoveryError)
    expect(@stopped).to be_empty
    registry.reject_ready = false
    observed = operation.observe
    drain
    expect(observed.wait_result.outcome).to eq(:not_prepared)
    expect(observed.wait_result.continuation_state).to eq(:stopped)
    expect(observed.wait_result.resolved?).to be(true)
    expect(@stopped).to eq([error])
    expect(@submitted.size).to eq(1)
  end

  it "does not infer pre-barrier failure from missing evidence after the barrier started" do
    allow(preparer).to receive(:prepare_provider) do |_command, on_barrier_started:, **_callbacks|
      on_barrier_started.call
      raise Phronomy::ExecutionRehydrationRequiredError, "barrier failed before complete proof"
    end
    operation.start
    complete_worker(0)
    observed = operation.observe
    drain
    expect(observed.wait_result.outcome).to eq(:unavailable)
    expect(observed.wait_result.resolved?).to be(false)
    expect(@stopped).to be_empty
    expect(registry.owner).to equal(operation)
  end

  it "requires applied complete post-state before granting continuation permission" do
    expect { operation.authorize_continuation! }.to raise_error(Phronomy::Error, /applied preparation proof/)
    expect(operation.continuation_authorized?).to be(false)
    expect { operation.continuation_completed! }.to raise_error(Phronomy::Error, /not been authorized/)
  end

  it "distinguishes continuation authorization from a normally returned admission call" do
    expect(operation.continuation_returned?).to be(false)
    expect { operation.continuation_returned! }.to raise_error(Phronomy::Error, /not been authorized/)
    start_unknown
    allow(evidence).to receive(:reconcile).and_return(proof(:committed))
    allow(coordinator).to receive(:apply_retained_dispatch_on_event_loop) do |owner, _result|
      owner.prepare_continuation
      owner.application_applied!
      expect(owner.authorize_continuation!).to be(true)
      expect(owner.continuation_returned?).to be(false)
      owner.continuation_returned!
      expect(owner.continuation_returned?).to be(true)
      owner.continuation_completed!
    end
    observed = operation.observe
    drain
    complete_worker(1)
    expect(observed.wait_result.resolved?).to be(true)
    expect(operation.continuation_returned?).to be(true)
  end

  it "retains authoritative cancellation from the complete persistence footprint" do
    expect(operation.captured_cancellation_requested?).to be(false)
    allow(evidence).to receive(:before).and_return([[{}, {}, [], nil, true], nil])
    start_unknown
    expect(operation.captured_cancellation_requested?).to be(true)
  end

  it "retains proof when authority no longer matches rather than applying to a replacement owner" do
    start_unknown
    registry.accept_owner = false
    observation = operation.observe
    drain
    expect(observation.wait_result.outcome).to eq(:unavailable)
    expect(@submitted.size).to eq(1)
    expect(@applied).to be_empty
    expect(operation.pending?).to be(true)
  end
end
