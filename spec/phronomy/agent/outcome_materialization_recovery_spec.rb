# frozen_string_literal: true

require "spec_helper"
require_relative "../../integration/support/hosted_subagent"

RSpec.describe "Native outcome materialization through the original Runtime" do
  include_context "a native child requiring approval"

  before do
    @runtime = Phronomy::Runtime.instance
    @counts = Hash.new(0)
    @gates = []
    @read_count = 0
    @materialization_count = 0
    @fault = :once
  end

  after do
    @validation_trace&.disable
    @approval_trace&.disable
    @gates.each { |waiting| waiting.fetch(:release) << true }
    @runtime.shutdown(timeout: 0.03, cancel_grace: 0.2)
  end

  def result_of(task) = task.wait_result(timeout: 8)
  def take(queue) = Timeout.timeout(8) { queue.pop }

  def eventually
    Timeout.timeout(8) do
      loop do
        found = yield
        return found if found
        sleep 0.002
      end
    end
  end

  def gate
    {entered: Queue.new, release: Queue.new}.tap { |waiting| @gates << waiting }
  end

  def setup_report(fault: :once, child: false, structured: false)
    @fault = fault
    @agent = parent
    counts = @counts
    reply = structured ? '{"answer":"captured report"}' : "captured answer"
    replies = if child
      [Phronomy::LLMAdapter::Response.new(finish_reason: :tool_calls, tool_calls: [
        Phronomy::Tool::CallRequest.new(id: "report-child", name: "dispatch_to_worker", arguments: {input: "review once"})
      ]), Phronomy::LLMAdapter::Response.new(content: "child reviewed", finish_reason: :stop)]
    else
      [Phronomy::LLMAdapter::Response.new(finish_reason: :tool_calls, tool_calls: [
        Phronomy::Tool::CallRequest.new(id: "report-tool", name: "no_approval_tool", arguments: {value: "once"})
      ])]
    end
    replies << Phronomy::LLMAdapter::Response.new(content: reply, finish_reason: :stop)
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |_request, cancellation_token:|
        cancellation_token&.raise_if_cancelled!
        counts[:provider] += 1
        replies.shift || raise("Unexpected Provider replay")
      end
    end.new
    Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
    unless structured
      @output = Object.new
      @output.define_singleton_method(:to_s) do
        counts[:output_conversion] += 1
        "captured report"
      end
      @agent.add_output_filter(->(_text) { @output })
    end
    allow_any_instance_of(IntegrationFactors::NoApprovalTool).to receive(:execute).and_wrap_original do |original, **options|
      @counts[:tool] += 1
      original.call(**options)
    end
    allow(Phronomy::Agent::RuntimeRecordEncoder).to receive(:encode).and_wrap_original do |original, *args, **options|
      @counts[:encoder] += 1
      original.call(*args, **options)
    end
    @validation_trace = TracePoint.new(:call) do |trace|
      if trace.defined_class == Phronomy::Agent::OutputContract && trace.method_id == :validate
        counts[:validation] += 1
      end
    end
    @validation_trace.enable
    allow_any_instance_of(Phronomy::MultiAgent::DurableSubagentCoordinator).to receive(:prepare_native_change).and_wrap_original do |original, *args|
      @counts[:native_plan] += 1
      original.call(*args)
    end
    install_transcript_read_fault
  end

  # The real materializer selects and decodes the real journal. Only a read of
  # old persisted content fails; newly staged content still uses its overlay.
  def install_transcript_read_fault
    allow_any_instance_of(Phronomy::Agent::RuntimeInput).to receive(:materialize_transcript).and_wrap_original do |original, **options|
      selected = options.fetch(:root).agent_id == @agent.agent_id
      Thread.current[:outcome_materialization_parent] = selected
      @materialization_count += 1 if selected
      original.call(**options)
    ensure
      Thread.current[:outcome_materialization_parent] = nil
    end
    allow_any_instance_of(Phronomy::Persistence::ContentRepository).to receive(:fetch).and_wrap_original do |original, reference|
      if Thread.current[:outcome_materialization_parent]
        @read_count += 1
        waiting = if @read_count == 1
          @initial_gate
        else
          ((@read_count == 2) ? @recovery_gate : nil)
        end
        if waiting
          waiting.fetch(:entered) << true
          waiting.fetch(:release).pop
        end
        if @fault != :none && (@fault != :once || @read_count == 1)
          failure = case @fault
          when :missing then Phronomy::Persistence::NotFoundError
          when :corrupt then Phronomy::ContentStore::IntegrityError
          else IOError
          end
          raise failure, "Immutable report transcript content is unavailable"
        end
      end
      original.call(reference)
    end
  end

  def start_report(**options)
    @original = @agent.invoke_async("prepare the report once", **options)
  end

  def await_retained_failure
    expect { result_of(@original) }.to raise_error(Phronomy::Agent::OutcomeRecoveryError) do |error|
      @failure, @recovery = error, error.recovery
    end
    @execution_id = @recovery.execution_id
    @prepared_counts = @counts.dup
    expect(@agent.pending_outcome_recovery(execution_id: @execution_id)).to equal(@recovery)
    expect { @agent.unload! }.to raise_error(Phronomy::AgentBusyError)
  end

  def saved_execution = stores.agent.executions.load(@execution_id)

  def assert_no_record_writes
    expect_any_instance_of(Phronomy::Persistence::ContentRepository).not_to receive(:put)
    expect_any_instance_of(Phronomy::Agent::Persistence::JournalRepository).not_to receive(:append)
    expect_any_instance_of(Phronomy::Agent::Persistence::ExecutionRepository).not_to receive(:save)
    expect_any_instance_of(Phronomy::Agent::Persistence::AgentRepository).not_to receive(:save)
  end

  def expect_captured_pre(receipt)
    expect(receipt.outcome).to eq(:confirmed_pre), receipt.error&.cause&.full_message
    expect(receipt.application_state).to eq(:pending)
    expect(receipt.ownership_state).to eq(:retained)
    expect(receipt.submission_state).to eq(:admitted)
    expect(saved_execution.status).to eq(:active)
    expect(@counts).to eq(@prepared_counts)
  end

  def expect_recovered(receipt, output: "captured report", unload: true)
    expect(receipt.outcome).to eq(:confirmed_post), receipt.error&.cause&.full_message
    expect(receipt.application_state).to eq(:applied)
    expect(receipt.ownership_state).to eq(:released)
    expect(receipt.execution.result).to eq(output)
    expect(receipt.execution).to eq(stores.agent.observe_execution(agent_id: @agent.agent_id, execution_id: @execution_id))
    expect(@counts).to eq(@prepared_counts)
    expect { result_of(@original) }.to raise_error { |error| expect(error).to equal(@failure) }
    transcript = @agent.transcript_messages
    expect(transcript.map(&:role)).to include(:user, :assistant, :tool)
    expect(transcript.last.content).to eq("captured answer") if output.is_a?(String)
    expect(@agent.unload!).to be(true) if unload
  end

  it "preserves the complete ordinary result and canonical transcript" do
    setup_report(fault: :none)
    start_report
    result = result_of(@original)
    expect(result.fetch(:output)).to equal(@output)
    expect(result.fetch(:messages).map(&:to_h)).to eq(@agent.transcript_messages.map(&:to_h))
    expect(result.fetch(:messages).map(&:role)).to include(:user, :assistant, :tool)
    expect(@counts).to include(provider: 2, tool: 1, output_conversion: 1)
    expect(@agent.unload!).to be(true)
  end

  it "finishes read-only hydration without replaying the encoded report or writing records" do
    setup_report
    start_report
    await_retained_failure
    assert_no_record_writes
    expect_captured_pre(@agent.reconcile_outcome(recovery: @recovery))
    expect(@counts).to include(provider: 2, tool: 1, output_conversion: 1)
    expect { result_of(@original) }.to raise_error { |error| expect(error).to equal(@failure) }
  end

  it "retries captured writes explicitly and settles a new exact observer with the durable result" do
    setup_report
    start_report
    await_retained_failure
    later = @agent.resume_async(@execution_id)
    eventually { @agent.__execution_environment.registry.agent_completion_waiters(@execution_id).any? }
    expect(later.done?).to be(false)
    expect_captured_pre(@agent.reconcile_outcome(recovery: @recovery))
    receipt = @agent.retry_outcome(recovery: @recovery)
    observation = result_of(later)
    expect(observation).to include(status: :completed, result: "captured report", output: "captured report")
    expect(observation).not_to have_key(:messages)
    expect_recovered(receipt)
  end

  it "preserves structured output and validates it only once across materialization recovery" do
    setup_report(structured: true)
    schema = {type: "object", properties: {answer: {type: "string"}}, required: ["answer"], additionalProperties: false}
    start_report(output_schema: schema)
    await_retained_failure
    expect(@counts[:validation]).to eq(1)
    expect_captured_pre(@agent.reconcile_outcome(recovery: @recovery))
    receipt = @agent.retry_outcome(recovery: @recovery)
    expect(receipt.execution.raw_output).to eq('{"answer":"captured report"}')
    expect_recovered(receipt, output: {"answer" => "captured report"})
  end

  it "publishes the captured bytes when the original output changes before hydration recovers" do
    setup_report
    text = +"captured report"
    @agent.add_output_filter(->(_output) { text })
    start_report
    await_retained_failure
    text.replace("changed after encoding")
    expect_captured_pre(@agent.reconcile_outcome(recovery: @recovery))
    expect_recovered(@agent.retry_outcome(recovery: @recovery))
    expect(text).to eq("changed after encoding")
    expect(text).not_to be_frozen
  end

  it "keeps successful hydration when later proof construction fails" do
    setup_report
    start_report
    await_retained_failure
    armed = true
    allow(Phronomy::Agent::TerminalPersistenceEvidence).to receive(:capture_values).and_wrap_original do |original, *args, **options|
      if armed
        armed = false
        raise IOError, "Read-only persistence proof construction is unavailable"
      end
      original.call(*args, **options)
    end
    failed = @agent.reconcile_outcome(recovery: @recovery)
    expect(failed.outcome).to eq(:unavailable)
    expect(failed.ownership_state).to eq(:retained)
    materializations = @materialization_count
    reads = @read_count
    expect_captured_pre(@agent.reconcile_outcome(recovery: @recovery))
    expect(@materialization_count).to eq(materializations)
    expect(@read_count).to eq(reads)
    receipt = @agent.retry_outcome(recovery: @recovery)
    expect(@materialization_count).to eq(materializations)
    expect(@read_count).to eq(reads)
    expect_recovered(receipt)
  end

  it "does not repeat a failed custom copy while constructing complete detached input" do
    setup_report
    counts = @counts
    value_class = Class.new(String) do
      define_method(:initialize_copy) do |source|
        if Thread.current[:materialization_detached_input]
          counts[:custom_copy] += 1
          raise IOError, "Original output cannot be copied again"
        end
        super(source)
      end
    end
    text = value_class.new("captured report")
    @agent.add_output_filter(->(_output) { text })
    allow(Phronomy::Agent::TerminalPersistenceEvidence::CapturedInput).to receive(:new).and_wrap_original do |original, *args, **options|
      Thread.current[:materialization_detached_input] = true
      original.call(*args, **options)
    ensure
      Thread.current[:materialization_detached_input] = nil
    end
    start_report
    await_retained_failure
    assert_no_record_writes
    first = @agent.reconcile_outcome(recovery: @recovery)
    expect(first.outcome).to eq(:unavailable)
    expect(first.error.cause.message).to eq("Original output cannot be copied again")
    counts_after_copy = @counts.dup
    expect(@counts[:custom_copy]).to eq(1)
    reads = @read_count
    2.times do
      receipt = @agent.retry_outcome(recovery: @recovery)
      expect(receipt.outcome).to eq(:unavailable)
      expect(receipt.ownership_state).to eq(:retained)
      expect(receipt.error.cause).to equal(first.error.cause)
    end
    expect(@counts).to eq(counts_after_copy)
    expect(@read_count).to eq(reads)
    expect(saved_execution.status).to eq(:active)
  end

  %i[persistent missing corrupt].each do |fault|
    it "retains custody while the captured transcript read remains #{fault}" do
      setup_report(fault: fault)
      start_report
      await_retained_failure
      expected_error = {persistent: IOError, missing: Phronomy::Persistence::NotFoundError, corrupt: Phronomy::ContentStore::IntegrityError}.fetch(fault)
      expect(@failure.cause).to be_a(expected_error)
      assert_no_record_writes
      2.times do
        receipt = @agent.retry_outcome(recovery: @recovery)
        expect(receipt.outcome).to eq(:unavailable)
        expect(receipt.error.cause).to be_a(expected_error)
        expect(receipt.application_state).to eq(:pending)
        expect(receipt.ownership_state).to eq(:retained)
      end
      expect(saved_execution.status).to eq(:active)
      expect(@counts).to eq(@prepared_counts)
    end
  end

  it "coalesces hydration observers and keeps an active read when one observer cancels" do
    setup_report
    start_report
    await_retained_failure
    @recovery_gate = gate
    first = @agent.reconcile_outcome_async(recovery: @recovery)
    take(@recovery_gate.fetch(:entered))
    second = @agent.reconcile_outcome_async(recovery: @recovery)
    first.cancel!
    blocked = result_of(@agent.retry_outcome_async(recovery: @recovery))
    expect(blocked.outcome).to eq(:unavailable)
    expect(blocked.ownership_state).to eq(:retained)
    expect(@read_count).to eq(2)
    expect(@counts).to eq(@prepared_counts)
    @recovery_gate.fetch(:release) << true
    expect_captured_pre(result_of(second))
    expect { result_of(first) }.to raise_error(Phronomy::CancellationError)
    reads = @read_count
    expect_recovered(@agent.retry_outcome(recovery: @recovery))
    expect(@read_count).to be >= reads
  end

  it "does not reuse a retained checkpoint with another Store identity" do
    setup_report
    start_report
    await_retained_failure
    allow(stores.agent).to receive(:execution_evidence_identity).and_return(Object.new)
    blocked = @agent.retry_outcome(recovery: @recovery)
    expect(blocked.outcome).to eq(:unavailable)
    expect(blocked.ownership_state).to eq(:retained)
    expect(saved_execution.status).to eq(:active)
    expect(@counts).to eq(@prepared_counts)
    allow(stores.agent).to receive(:execution_evidence_identity).and_call_original
    expect_recovered(@agent.retry_outcome(recovery: @recovery))
  end

  it "does not overwrite a changed durable execution after hydration" do
    setup_report
    start_report
    await_retained_failure
    current = saved_execution
    stores.agent.executions.save(@execution_id, expected_revision: current.execution_revision,
      execution: current.with(metadata: current.metadata.merge("other_owner" => true)))
    changed = saved_execution.to_h
    assert_no_record_writes
    receipt = @agent.retry_outcome(recovery: @recovery)
    expect(receipt.outcome).to eq(:unresolved)
    expect(receipt.ownership_state).to eq(:retained)
    expect(saved_execution.to_h).to eq(changed)
    expect(@counts).to eq(@prepared_counts)
  end

  it "retains the exact plan when cancellation changes its guarded facts" do
    setup_report
    start_report
    await_retained_failure
    result_of(@agent.cancel_async(@execution_id))
    expect(stores.agent.cancellation_requested?(agent_id: @agent.agent_id, execution_id: @execution_id)).to be(true)
    assert_no_record_writes
    receipt = @agent.retry_outcome(recovery: @recovery)
    expect(receipt.outcome).to eq(:unresolved)
    expect(receipt.ownership_state).to eq(:retained)
    expect(saved_execution.status).to eq(:active)
    expect(@counts).to eq(@prepared_counts)
  end

  it "waits for the original physical reader after its logical timeout" do
    setup_report
    @initial_gate = gate
    pool = @runtime.offload
    allow_any_instance_of(Phronomy::Agent::OutcomeRecoveryOperation).to receive(:start).and_wrap_original do |original|
      allow(pool).to receive(:submit).and_wrap_original do |submit, **options, &work|
        submit.call(**options.merge(timeout: 0.02), &work)
      end
      original.call
    end
    start_report
    take(@initial_gate.fetch(:entered))
    eventually { pool.abandoned_active_count == 1 }
    await_retained_failure
    blocked = @agent.retry_outcome(recovery: @recovery)
    expect(blocked.outcome).to eq(:unavailable)
    expect(blocked.ownership_state).to eq(:retained)
    expect(@read_count).to eq(1)
    expect(@counts).to eq(@prepared_counts)
    allow(pool).to receive(:submit).and_call_original
    @initial_gate.fetch(:release) << true
    eventually { pool.abandoned_active_count.zero? }
    expect_captured_pre(@agent.reconcile_outcome(recovery: @recovery))
    expect_recovered(@agent.retry_outcome(recovery: @recovery))
  end

  it "checks current child custody before replaying a hydrated parent outcome" do
    setup_report(child: true)
    start_report
    await_retained_failure
    extension = stores.agent.execution_extension(agent_id: @agent.agent_id, execution_id: @execution_id,
      binding_key: Phronomy::MultiAgent::DurableSubagentCoordinator::BINDING_KEY)
    child = stores.multi_agent.contents.fetch_json(extension.state_ref).fetch("children").fetch(0)
    hold = stores.agent.retained_references(agent_id: child.fetch("agent_id")).find do |value|
      value.owner_key == "subagent:#{@execution_id}"
    end
    expect(hold).not_to be_nil
    stores.agent.coordinator.atomic do |scope|
      stores.agent.release_retention(agent_id: child.fetch("agent_id"), owner_key: hold.owner_key, scope: scope)
    end
    expect_captured_pre(@agent.reconcile_outcome(recovery: @recovery))
    blocked = @agent.retry_outcome(recovery: @recovery)
    expect(blocked.outcome).to eq(:confirmed_pre)
    expect(blocked.ownership_state).to eq(:retained)
    expect(blocked.error.cause).to be_a(Phronomy::Persistence::StateConflictError)
    expect(@counts).to eq(@prepared_counts)
    stores.agent.retain(hold)
    receipt = @agent.retry_outcome(recovery: @recovery)
    expect(receipt.outcome).to eq(:confirmed_post), receipt.error&.cause&.full_message
    expect(receipt.execution.result).to eq("captured report")
    expect(@counts).to eq(@prepared_counts)
    expect(@counts[:provider]).to eq(3)
    expect { result_of(@original) }.to raise_error { |error| expect(error).to equal(@failure) }
    expect(@agent.unload_with_completed_child!(@execution_id, execution_id: child.fetch("execution_id"))).to be(true)
  end

  it "does not replay incomplete approval conversion through the transcript checkpoint" do
    worker, protected_tool = child_class, approval_tool
    klass = Class.new(Phronomy::MultiAgent::Orchestrator) do
      agent_definition id: "materialization-approval-scope", version: 1
      tools protected_tool => nil
      subagent :worker, worker
    end
    @agent = klass.create(persistence: stores.agent, coordination_store: stores.multi_agent)
    counts = @counts
    response = Phronomy::LLMAdapter::Response.new(finish_reason: :tool_calls, tool_calls: [
      Phronomy::Tool::CallRequest.new(id: "approval-call", name: "approval_required_tool", arguments: {query: "check once"})
    ])
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |_request, cancellation_token:|
        cancellation_token&.raise_if_cancelled!
        counts[:provider] += 1
        raise "Unexpected Provider replay" if counts[:provider] > 1
        response
      end
    end.new
    Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
    allow_any_instance_of(protected_tool).to receive(:execute) { raise "An approval was not granted" }
    allow(Phronomy::Agent::TerminalPersistenceEvidence).to receive(:detached_outcome).and_wrap_original do |original, *args|
      Thread.current[:materialization_approval_conversion] = true
      original.call(*args)
    ensure
      Thread.current[:materialization_approval_conversion] = nil
    end
    @approval_trace = TracePoint.new(:call) do |trace|
      if Thread.current[:materialization_approval_conversion] &&
          trace.defined_class == Phronomy::Agent::ToolApprovalRequest && trace.method_id == :to_h
        counts[:approval_conversion] += 1
        raise IOError, "Approval conversion failed before complete input"
      end
    end
    @approval_trace.enable
    start_report
    await_retained_failure
    expect(@failure.cause).to be_a(IOError)
    expect(@counts).to include(provider: 1, approval_conversion: 1)
    assert_no_record_writes
    %i[reconcile_outcome retry_outcome retry_outcome_submission].each do |method|
      receipt = @agent.public_send(method, recovery: @recovery)
      expect(receipt.outcome).to eq(:unavailable)
      expect(receipt.ownership_state).to eq(:retained)
      expect(receipt.submission_state).to eq(:admitted)
    end
    expect(@counts).to eq(@prepared_counts)
    expect(saved_execution.status).to eq(:active)
  end
end
