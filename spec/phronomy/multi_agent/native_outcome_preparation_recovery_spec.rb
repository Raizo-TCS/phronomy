# frozen_string_literal: true

require "spec_helper"
require_relative "../../integration/support/hosted_subagent"

RSpec.describe "Native outcome preparation recovery through the original Runtime" do
  include_context "a native child requiring approval"

  let(:effects) { [] }
  let(:approval_tool) do
    recorded = effects
    Class.new(Phronomy::Tool::Base) do
      tool_name "approval_required_tool"
      description "Records one authorized effect"
      param :query, type: :string, desc: "Approved input"
      requires_approval true
      define_method(:execute) do |query:|
        recorded << query
        "approved #{query}"
      end
    end
  end
  let(:parent_class) do
    worker, protected_tool = child_class, approval_tool
    Class.new(Phronomy::MultiAgent::Orchestrator) do
      agent_definition id: "native-outcome-preparation", version: 1
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
    @runtime = Phronomy::Runtime.instance
    @counts = Hash.new(0)
    allow_any_instance_of(Phronomy::Agent::ExecutionOutcomeCommitter).to receive(:commit_outcome).and_wrap_original do |original, command, **options|
      selected = command.execution_id == root_id
      Thread.current[:native_preparation_runtime] = selected
      @counts[:committer] += 1 if selected
      original.call(command, **options)
    ensure
      Thread.current[:native_preparation_runtime] = nil
    end
    count_boundary(Phronomy::Agent::ExecutionOutcomeCommitter, :prepare_terminal_outcome, :builder)
    count_boundary(Phronomy::MultiAgent::DurableSubagentCoordinator, :commit_prepared_outcome, :native)
    count_class_boundary(Phronomy::Agent::RuntimeRecordEncoder, :encode, :encoder)
    count_class_boundary(Phronomy::Agent::OutputContract, :restore, :validation)
  end

  after do
    @gates&.each { |waiting| waiting.fetch(:release) << true }
    @runtime.shutdown(timeout: 0.03, cancel_grace: 0.2)
  end

  def count_boundary(klass, method, key)
    allow_any_instance_of(klass).to receive(method).and_wrap_original do |original, *args, **options, &work|
      @counts[key] += 1 if Thread.current[:native_preparation_runtime]
      original.call(*args, **options, &work)
    end
  end

  def count_class_boundary(klass, method, key)
    allow(klass).to receive(method).and_wrap_original do |original, *args, **options, &work|
      @counts[key] += 1 if Thread.current[:native_preparation_runtime]
      original.call(*args, **options, &work)
    end
  end

  def gate
    {entered: Queue.new, release: Queue.new}.tap { |waiting| (@gates ||= []) << waiting }
  end

  def take(queue) = Timeout.timeout(8) { queue.pop }
  def result_of(task) = task.wait_result(timeout: 8)

  def eventually
    Timeout.timeout(8) do
      loop do
        found = yield
        return found if found
        sleep 0.002
      end
    end
  end

  def start_parent(kind)
    responses = case kind
    when :terminal then ["parent completed"]
    when :approval_wait then [protected_call, "parent completed"]
    when :coordination_wait then [dispatch, protected_call, "child completed", "parent completed"]
    end
    @recorder = LLMStub.activate(responses: responses)
    reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: root_id)
    @original = parent.start_hosted(reservation: reservation, input: "run", config: {cancellation_token: token})
  end

  def await_retained_failure
    expect { result_of(@original) }.to raise_error(Phronomy::Agent::OutcomeRecoveryError) do |error|
      @failure, @recovery = error, error.recovery
    end
    expect(parent.pending_outcome_recovery(execution_id: root_id)).to equal(@recovery)
    expect(parent.__execution_environment.registry.agent_execution_admitted?(parent.agent_id)).to be(true)
    expect { parent.unload! }.to raise_error(Phronomy::AgentBusyError)
    expect(effects).to be_empty
    @prepared_counts = @counts.dup
    expect(@prepared_counts[:committer]).to eq(1)
    expect(@prepared_counts[:native]).to eq(1)
  end

  def expect_prepared_work_unchanged
    expect(@counts).to eq(@prepared_counts)
    expect { result_of(@original) }.to raise_error { |error| expect(error).to equal(@failure) }
    expect(effects).to be_empty
  end

  def expect_recovered(receipt, kind, unload: true)
    expect(receipt.outcome).to eq(:confirmed_post), receipt.error&.cause&.full_message
    expect(receipt.application_state).to eq(:applied), receipt.error&.cause&.full_message
    expect(receipt.ownership_state).to eq(:released)
    expect(receipt.saved_outcome).to eq(kind)
    expect_prepared_work_unchanged
    if kind == :terminal
      expect(receipt.execution.result).to eq("parent completed")
      expect(@recorder.calls.size).to eq(1)
      expect(parent.unload!).to be(true) if unload
    elsif kind == :approval_wait
      expect(receipt.execution).to be_nil
      expect(receipt.approval_request.execution_id).to eq(root_id)
      expect(stores.agent.executions.load(root_id).status).to eq(:suspended)
      expect(parent.__execution_environment.registry.agent_execution_admitted?(parent.agent_id)).to be(true)
      expect(@recorder.calls.size).to eq(1)
      expect(events).to be_empty
      request = receipt.approval_request
      result = result_of(parent.approve_async(root_id, approval_request_id: request.id, approved: true))
      expect(result).to include(output: "parent completed")
      expect(effects).to eq(["check"])
      expect(@recorder.calls.size).to eq(2)
      expect(parent.unload!).to be(true)
    else
      expect(receipt.execution).to be_nil
      expect(stores.agent.executions.load(root_id).status).to eq(:active)
      expect(parent.__execution_environment.registry.agent_execution_admitted?(parent.agent_id)).to be(false)
      expect(@recorder.calls.size).to eq(2)
      request = take(events)
      child = child_class.get(stores.agent.execution_identity(request.execution_id).agent_id)
      result_of(child.approve_async(request.execution_id, approval_request_id: request.id, approved: true))
      expect(parent.resume(root_id)).to include(output: "parent completed")
      expect(effects).to eq(["check"])
      expect(@recorder.calls.size).to eq(4)
      expect(parent.unload_with_completed_child!(root_id, execution_id: request.execution_id)).to be(true)
    end
    expect { result_of(@original) }.to raise_error { |error| expect(error).to equal(@failure) }
  end

  def lose_content_write(position, after: false)
    @content_attempts = 0
    armed = true
    allow_any_instance_of(Phronomy::ContentStore::StoredContents).to receive(:put).and_wrap_original do |original, *args, **options|
      selected = armed && Thread.current[:native_preparation_runtime]
      @content_attempts += 1 if selected
      if selected && @content_attempts == position
        armed = false
        original.call(*args, **options) if after
        raise IOError, "prepared outcome content response unavailable"
      end
      original.call(*args, **options)
    end
  end

  %i[terminal approval_wait coordination_wait].each do |kind|
    boundaries = (kind == :coordination_wait) ? [[1, false], [1, true]] : [[1, false], [2, true]]
    boundaries.each do |position, after|
      it "recovers #{kind} after content put #{position} fails #{after ? "after" : "before"} its write" do
        lose_content_write(position, after: after)
        start_parent(kind)
        await_retained_failure
        before = parent.reconcile_outcome(recovery: @recovery)
        expect(before.outcome).to eq(:confirmed_pre), before.error&.cause&.full_message
        expect(before.ownership_state).to eq(:retained)
        expect(before.submission_state).to eq(:admitted)
        expect(before.saved_outcome).to be_nil
        expect_prepared_work_unchanged
        expect_recovered(parent.retry_outcome(recovery: @recovery), kind)
        expect(@content_attempts).to eq(position)
      end
    end
  end

  it "validates a real output schema once before retrying its exact native save" do
    schema = {type: "object", properties: {answer: {type: "string"}}, required: ["answer"], additionalProperties: false}
    @recorder = LLMStub.activate(responses: ['{"answer":"parent completed"}'])
    lose_content_write(2, after: true)
    validation = TracePoint.new(:call) do |event|
      if Thread.current[:native_preparation_runtime] && event.defined_class == Phronomy::Agent::OutputContract && event.method_id == :validate
        @counts[:schema_validation] += 1
      end
    end
    validation.enable(target_thread: nil) do
      reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: root_id)
      @original = parent.start_hosted(reservation: reservation, input: "run", output_schema: schema,
        config: {cancellation_token: token})
      await_retained_failure
      expect(@prepared_counts[:schema_validation]).to eq(1)
      expect(@prepared_counts[:encoder]).to eq(1)
      expect(stores.agent.executions.load(root_id).metadata).to have_key("output_contract")
      before = parent.reconcile_outcome(recovery: @recovery)
      expect(before.outcome).to eq(:confirmed_pre), before.error&.cause&.full_message
      expect_prepared_work_unchanged

      receipt = parent.retry_outcome(recovery: @recovery)

      expect(receipt.outcome).to eq(:confirmed_post), receipt.error&.cause&.full_message
      expect(receipt.application_state).to eq(:applied)
      expect(receipt.ownership_state).to eq(:released)
      expect(receipt.saved_outcome).to eq(:terminal)
      expect(receipt.execution.status).to eq(:completed)
      expect(receipt.execution.result).to eq("answer" => "parent completed")
      expect_prepared_work_unchanged
      expect(@counts[:schema_validation]).to eq(1)
      expect(@recorder.calls.size).to eq(1)
      expect(parent.unload!).to be(true)
    end
  end

  it "rebuilds a transiently unavailable proof from the same complete preparation without repeating callbacks" do
    captured_values = []
    allow(Phronomy::MultiAgent::NativeOutcomeEvidence).to receive(:capture).and_wrap_original do |original, **options|
      captured_values << options.fetch(:values)
      raise IOError, "detached proof temporarily unavailable" if captured_values.size == 1
      original.call(**options)
    end
    start_parent(:terminal)
    await_retained_failure
    expect(stores.agent.executions.load(root_id).status).to eq(:active)
    receipt = parent.reconcile_outcome(recovery: @recovery)
    expect(receipt.outcome).to eq(:confirmed_pre), receipt.error&.cause&.full_message
    expect(captured_values.size).to eq(2)
    expect(captured_values.last).to eq(captured_values.first)
    expect_prepared_work_unchanged
    expect_recovered(parent.retry_outcome(recovery: @recovery), :terminal)
    expect(captured_values.size).to eq(2)
  end

  it "retains the planned post-state when verification fails after the original writes" do
    writes = 0
    faulted = false
    allow_any_instance_of(Phronomy::ContentStore::StoredContents).to receive(:put).and_wrap_original do |original, *args, **options|
      writes += 1 if Thread.current[:native_preparation_runtime]
      original.call(*args, **options)
    end
    allow(Phronomy::Agent::ExecutionChange).to receive(:read_agent_evidence).and_wrap_original do |original, **options|
      if Thread.current[:native_preparation_runtime] && writes.positive? && !faulted
        faulted = true
        raise IOError, "prepared post-write verification unavailable"
      end
      original.call(**options)
    end
    start_parent(:terminal)
    await_retained_failure
    expect(faulted).to be(true)
    expect(@failure.cause.message).to include("prepared post-write verification unavailable")
    expect(stores.agent.executions.load(root_id).status).to eq(:active)
    receipt = parent.reconcile_outcome(recovery: @recovery)
    expect(receipt.outcome).to eq(:confirmed_pre), receipt.error&.cause&.full_message
    expect_prepared_work_unchanged
    expect_recovered(parent.retry_outcome(recovery: @recovery), :terminal)
  end

  it "keeps complete preparation held while the original timed-out write is physically active" do
    waiting = gate
    armed = true
    pool = @runtime.offload
    allow_any_instance_of(Phronomy::Agent::OutcomeRecoveryOperation).to receive(:start).and_wrap_original do |original|
      if original.receiver.execution_id == root_id
        allow(pool).to receive(:submit).and_wrap_original do |submit, **options, &work|
          submit.call(**options.merge(timeout: 0.02), &work)
        end
      end
      original.call
    end
    allow_any_instance_of(Phronomy::ContentStore::StoredContents).to receive(:put).and_wrap_original do |original, *args, **options|
      if armed && Thread.current[:native_preparation_runtime]
        armed = false
        waiting.fetch(:entered) << true
        waiting.fetch(:release).pop
      end
      original.call(*args, **options)
    end
    start_parent(:terminal)
    take(waiting.fetch(:entered))
    eventually { pool.abandoned_active_count == 1 }
    await_retained_failure
    expect(parent.reconcile_outcome(recovery: @recovery).outcome).to eq(:unavailable)
    expect(parent.retry_outcome(recovery: @recovery).ownership_state).to eq(:retained)
    expect_prepared_work_unchanged
    allow(pool).to receive(:submit).and_call_original
    waiting.fetch(:release) << true
    eventually { pool.abandoned_active_count.zero? }
    expect_recovered(parent.reconcile_outcome(recovery: @recovery), :terminal)
  end

  it "coalesces independent read observers and retains the work when one observer cancels" do
    lose_content_write(1)
    start_parent(:terminal)
    await_retained_failure
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
    receipt = result_of(second)
    expect(receipt.outcome).to eq(:confirmed_pre), receipt.error&.cause&.full_message
    expect(reads).to eq(1)
    expect { result_of(first) }.to raise_error(Phronomy::CancellationError)
    allow(stores.agent.coordinator).to receive(:atomic).and_call_original
    expect_recovered(parent.retry_outcome(recovery: @recovery), :terminal)
  end

  it "does not replay a prepared outcome over a conflicting execution state" do
    lose_content_write(1)
    start_parent(:terminal)
    await_retained_failure
    current = stores.agent.executions.load(root_id)
    stores.agent.executions.save(root_id, expected_revision: current.execution_revision,
      execution: current.with(metadata: current.metadata.merge("another_writer" => true)))
    saved = stores.agent.executions.load(root_id).to_h
    writes = 0
    allow_any_instance_of(Phronomy::ContentStore::StoredContents).to receive(:put).and_wrap_original do |original, *args, **options|
      writes += 1
      original.call(*args, **options)
    end
    [:reconcile_outcome, :retry_outcome].each do |method|
      receipt = parent.public_send(method, recovery: @recovery)
      expect(receipt.outcome).to eq(:unresolved)
      expect(receipt.application_state).to eq(:pending)
      expect(receipt.ownership_state).to eq(:retained)
    end
    expect(writes).to eq(0)
    expect(stores.agent.executions.load(root_id).to_h).to eq(saved)
    expect_prepared_work_unchanged
    expect(@recorder.calls.size).to eq(1)
  end

  it "compares unrelated parent holds as facts when storage enumeration order changes" do
    holds = %w[application:a application:z].map do |owner|
      Phronomy::Agent::Retention.new(agent_id: parent.agent_id, owner_key: owner)
    end
    holds.each { |hold| stores.agent.retain(hold) }
    enumerations = []
    reverse = false
    allow(stores.agent).to receive(:retained_references).and_wrap_original do |original, **options|
      values = original.call(**options)
      next values unless options.fetch(:agent_id) == parent.agent_id
      ordered = values.sort_by(&:owner_key)
      reverse = !reverse
      ordered.reverse! if reverse
      enumerations << ordered.map(&:owner_key)
      ordered.freeze
    end
    lose_content_write(1)
    start_parent(:terminal)
    await_retained_failure
    receipt = parent.reconcile_outcome(recovery: @recovery)
    expect(receipt.outcome).to eq(:confirmed_pre), receipt.error&.cause&.full_message
    expect_prepared_work_unchanged
    expect_recovered(parent.retry_outcome(recovery: @recovery), :terminal, unload: false)
    expect(stores.agent.retained_references(agent_id: parent.agent_id)).to match_array(holds)
    expect(enumerations).to include(%w[application:a application:z], %w[application:z application:a])
    expect { parent.unload! }.to raise_error(Phronomy::AgentBusyError)
    stores.agent.coordinator.atomic do |scope|
      holds.each do |hold|
        stores.agent.release_retention(agent_id: parent.agent_id, owner_key: hold.owner_key, scope: scope)
      end
    end
    expect(parent.unload!).to be(true)
  end

  it "requires current child custody before replaying a prepared coordination wait" do
    lose_content_write(1)
    start_parent(:coordination_wait)
    await_retained_failure
    request = take(events)
    child = child_class.get(stores.agent.execution_identity(request.execution_id).agent_id)
    hold = stores.agent.retained_references(agent_id: child.agent_id).find do |value|
      value.owner_key == "subagent:#{root_id}"
    end
    expect(hold).not_to be_nil
    stores.agent.coordinator.atomic do |scope|
      stores.agent.release_retention(agent_id: child.agent_id, owner_key: hold.owner_key, scope: scope)
    end
    writes = 0
    allow_any_instance_of(Phronomy::ContentStore::StoredContents).to receive(:put).and_wrap_original do |original, *args, **options|
      writes += 1
      original.call(*args, **options)
    end
    blocked = parent.retry_outcome(recovery: @recovery)
    expect(blocked.outcome).to eq(:confirmed_pre)
    expect(blocked.ownership_state).to eq(:retained)
    expect(blocked.error.cause).to be_a(Phronomy::Persistence::StateConflictError)
    expect(writes).to eq(0)
    expect(@recorder.calls.size).to eq(2)
    expect_prepared_work_unchanged
    stores.agent.retain(hold)
    events << request
    expect_recovered(parent.retry_outcome(recovery: @recovery), :coordination_wait)
  end
end
