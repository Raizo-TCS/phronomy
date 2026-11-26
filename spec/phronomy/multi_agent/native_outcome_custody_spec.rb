# frozen_string_literal: true

require "spec_helper"
require_relative "../../integration/support/hosted_subagent"

RSpec.describe "Native approval-wait outcome attempt custody" do
  include_context "a native child requiring approval"

  let(:parent_class) do
    worker, protected_tool = child_class, approval_tool
    Class.new(Phronomy::MultiAgent::Orchestrator) do
      agent_definition id: "native-outcome-custody", version: 1
      model IntegrationFactors::LM_MODEL_30
      provider :openai
      tools protected_tool => nil
      subagent :worker, worker
    end
  end

  before do
    RubyLLM.configure do |configuration|
      configuration.openai_protocol = :chat_completions
      configuration.openai_api_key = "test"
    end
    Phronomy.configure do |configuration|
      configuration.offload_pool_size = 1
      configuration.offload_queue_size = 1
    end
    @runtime = Phronomy::Runtime.instance
    @recorder = LLMStub.activate(responses: [protected_call])
  end

  after do
    @gates&.each { |waiting| waiting.fetch(:release) << true }
    @runtime.shutdown(timeout: 0.03, cancel_grace: 0.2)
  end

  def gate
    {entered: Queue.new, release: Queue.new}.tap { |waiting| (@gates ||= []) << waiting }
  end

  def take(queue) = Timeout.timeout(8) { queue.pop }
  def result_of(task) = task.wait_result(timeout: 8)

  def eventually
    Timeout.timeout(8) do
      loop do
        result = yield
        return result if result
        sleep 0.002
      end
    end
  end

  def start_parent
    reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: root_id)
    @original = parent.start_hosted(reservation: reservation, input: "wait")
  end

  def await_recovery
    expect { result_of(@original) }.to raise_error(Phronomy::Agent::OutcomeRecoveryError) do |error|
      @failure, @recovery = error, error.recovery
    end
    expect(parent.pending_outcome_recovery(execution_id: root_id)).to equal(@recovery)
    expect(parent.pending_terminal_recovery(execution_id: root_id)).to be_nil
  end

  def expect_wait(receipt)
    expect(receipt.outcome).to eq(:confirmed_post), receipt.error&.cause&.full_message
    expect(receipt.saved_outcome).to eq(:approval_wait)
    expect(receipt.application_state).to eq(:applied)
    expect(receipt.ownership_state).to eq(:released)
    expect(receipt.approval_request.execution_id).to eq(root_id)
    expect(receipt.execution).to be_nil
    expect(parent.__execution_environment.registry.agent_execution_admitted?(parent.agent_id)).to be(true)
    expect(stores.agent.executions.load(root_id).status).to eq(:suspended)
    expect(@recorder.calls.size).to eq(1)
    expect(events).to be_empty
    expect { result_of(@original) }.to raise_error { |error| expect(error).to equal(@failure) }
  end

  it "keeps an accepted wait read after one recovery observer cancels" do
    allow_any_instance_of(Phronomy::Agent::ExecutionOutcomeCommitter).to receive(:commit_outcome).and_wrap_original do |original, *args, **options|
      original.call(*args, **options)
      raise IOError, "saved wait response lost"
    end
    start_parent
    await_recovery
    waiting = gate
    reads = 0
    allow(stores.agent.coordinator).to receive(:atomic).and_wrap_original do |original, *args, &work|
      reads += 1
      waiting.fetch(:entered) << true
      waiting.fetch(:release).pop
      original.call(*args, &work)
    end
    first = parent.reconcile_outcome_async(recovery: @recovery)
    take(waiting.fetch(:entered))
    second = parent.reconcile_outcome_async(recovery: @recovery)
    first.cancel!
    expect(first.status).to eq(:cancelled)
    expect(parent.pending_outcome_recovery(execution_id: root_id)).to equal(@recovery)
    waiting.fetch(:release) << true
    expect_wait(result_of(second))
    expect(reads).to eq(1)
    expect { result_of(first) }.to raise_error(Phronomy::CancellationError)
  end

  it "keeps a timed-out wait save until its physical worker ends" do
    pool = @runtime.offload
    waiting = gate
    allow_any_instance_of(Phronomy::Agent::OutcomeRecoveryOperation).to receive(:start).and_wrap_original do |original|
      allow(pool).to receive(:submit).and_wrap_original do |submit, **options, &work|
        submit.call(**options.merge(timeout: 0.02), &work)
      end
      original.call
    end
    allow_any_instance_of(Phronomy::Agent::ExecutionOutcomeCommitter).to receive(:commit_outcome).and_wrap_original do |original, *args, **options|
      original.call(*args, **options).tap do
        waiting.fetch(:entered) << true
        waiting.fetch(:release).pop
      end
    end
    start_parent
    take(waiting.fetch(:entered))
    eventually { pool.abandoned_active_count == 1 }
    await_recovery
    expect(parent.reconcile_outcome(recovery: @recovery).outcome).to eq(:unavailable)
    expect(parent.retry_outcome(recovery: @recovery).ownership_state).to eq(:retained)
    expect(pool.abandoned_active_count).to eq(1)
    allow(pool).to receive(:submit).and_call_original
    waiting.fetch(:release) << true
    eventually { pool.abandoned_active_count.zero? }
    expect_wait(parent.reconcile_outcome(recovery: @recovery))
    expect(pool.abandoned_active_count).to eq(0)
  end

  it "resubmits a positively refused wait save once without repeating the Provider" do
    boundary, occupied = gate, gate
    allow_any_instance_of(Phronomy::Agent::ExecutionCoordinator).to receive(:submit_terminal_operation).and_wrap_original do |original, *args|
      boundary.fetch(:entered) << true
      boundary.fetch(:release).pop
      original.call(*args)
    end
    start_parent
    take(boundary.fetch(:entered))
    running = @runtime.offload.submit(on_full: :raise) do
      occupied.fetch(:entered) << true
      occupied.fetch(:release).pop
    end
    take(occupied.fetch(:entered))
    queued = @runtime.offload.submit(on_full: :raise) { :queued }
    boundary.fetch(:release) << true
    await_recovery
    refused = parent.reconcile_outcome(recovery: @recovery)
    expect(refused.outcome).to eq(:unavailable)
    expect(refused.submission_state).to eq(:not_admitted)
    expect(refused.saved_outcome).to be_nil
    expect(@failure.cause).to be_a(Phronomy::BackpressureError)
    expect(events).to be_empty
    occupied.fetch(:release) << true
    result_of(running)
    result_of(queued)
    expect_wait(parent.retry_outcome_submission(recovery: @recovery))
    expect_wait(parent.retry_outcome_submission(recovery: @recovery))
  end

  it "retains an admitted incomplete wait proposal without replaying its failed encoder" do
    calls = 0
    allow_any_instance_of(Phronomy::Agent::ExecutionOutcomeCommitter).to receive(:commit_outcome).and_wrap_original do |original, *args, **options|
      Thread.current[:native_outcome_encoding] = true
      original.call(*args, **options)
    ensure
      Thread.current[:native_outcome_encoding] = nil
    end
    allow(Phronomy::Agent::RuntimeRecordEncoder).to receive(:encode).and_wrap_original do |original, *args, **options|
      if Thread.current[:native_outcome_encoding]
        calls += 1
        raise IOError, "wait encoding failed before a complete proposal"
      end
      original.call(*args, **options)
    end
    start_parent
    await_recovery
    [:reconcile_outcome, :retry_outcome, :retry_outcome_submission].each do |method|
      receipt = parent.public_send(method, recovery: @recovery)
      expect(receipt.outcome).to eq(:unavailable)
      expect(receipt.application_state).to eq(:pending)
      expect(receipt.ownership_state).to eq(:retained)
      expect(receipt.submission_state).to eq(:admitted)
      expect(receipt.saved_outcome).to be_nil
    end
    expect(calls).to eq(1)
    expect(@recorder.calls.size).to eq(1)
    expect(events).to be_empty
    expect(stores.agent.executions.load(root_id).status).to eq(:active)
  end
end
