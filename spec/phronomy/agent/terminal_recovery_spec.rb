# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe "Agent terminal recovery through its original Runtime" do
  Gate = Struct.new(:entered, :release)

  def eventually
    Timeout.timeout(4) do
      loop do
        value = yield
        return value if value
        sleep 0.002
      end
    end
  end

  def take(queue)
    Timeout.timeout(4) { queue.pop }
  end

  def result_of(task)
    task.wait_result(timeout: 4)
  end

  def gate
    Gate.new(entered: Queue.new, release: Queue.new).tap { |value| (@gates ||= []) << value }
  end

  def setup_agent(mode: :post, response: "retained answer", provider_error: nil, tools: false)
    @runtime = Phronomy::Runtime.instance
    @registry = Phronomy::Agent::ExecutionRegistry.for(@runtime.event_loop)
    @store = Phronomy::PersistenceComposition.in_memory.agent
    @counts = counts = Hash.new(0)
    replies = [Phronomy::LLMAdapter::Response.new(content: response, finish_reason: :stop)]
    tool_class = Class.new(Phronomy::Tool::Base) do
      tool_name "terminal_recovery_tool"
      description "Performs the one authorized action"
      param :value, type: :string, desc: "Action input"
      define_method(:execute) do |value:|
        counts[:tool] += 1
        "observed #{value}"
      end
    end
    if tools
      replies.unshift(Phronomy::LLMAdapter::Response.new(finish_reason: :tool_calls, tool_calls: [
        Phronomy::Tool::CallRequest.new(id: "terminal-recovery-call", name: "terminal_recovery_tool", arguments: {value: "once"})
      ]))
    end
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |_request, cancellation_token:|
        cancellation_token&.raise_if_cancelled!
        counts[:provider] += 1
        raise provider_error if provider_error
        replies.shift || Phronomy::LLMAdapter::Response.new(content: "next answer", finish_reason: :stop)
      end
    end.new
    @adapter = adapter
    Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
    @agent_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "terminal-recovery-runtime", version: 1
      tools tool_class => nil if tools
    end
    @events = []
    @agent = @agent_class.create(agent_id: "terminal-recovery-#{RSpec.current_example.metadata.fetch(:line_number)}",
      persistence: @store, on_event: ->(event) { @events << event })
    install_save_fault(mode)
  end

  # Only the storage fault is synthetic. The real Runtime performs admission,
  # provider/Tool execution, terminal construction, readback and owner delivery.
  def install_save_fault(mode)
    @fault = fault = {armed: mode != :none, terminal: false, read_failure: false, recovery_loads: 0}
    allow_any_instance_of(Phronomy::Agent::ExecutionOutcomeCommitter)
      .to receive(:commit_outcome).and_wrap_original do |original, operation, **options|
        if fault[:armed]
          fault[:terminal] = true
          fault[:execution_id] = operation.execution_id
        end
        original.call(operation, **options)
      end
    allow(@store.coordinator).to receive(:atomic).and_wrap_original do |original, &transaction|
      if fault[:armed] && fault[:terminal]
        fault[:armed] = false
        @counts[:initial_terminal_transaction] += 1
        if (waiting = fault.delete(:next_save_gate))
          waiting.entered << true
          waiting.release.pop
        end
        if mode == :pre
          original.call do |scope|
            transaction.call(scope)
            fault[:read_failure] = true
            raise IOError, "terminal transaction rolled back after complete proposal"
          end
        else
          original.call(&transaction)
          fault[:read_failure] = true
          raise IOError, "terminal transaction committed but reply was lost"
        end
      else
        original.call(&transaction)
      end
    end
    allow_any_instance_of(Phronomy::Agent::Persistence::ExecutionRepository)
      .to receive(:load).and_wrap_original do |original, execution_id|
        if fault[:read_failure]
          fault[:read_failure] = false
          raise IOError, "first authoritative terminal readback unavailable"
        end
        if fault[:observing] && execution_id == fault[:execution_id]
          fault[:recovery_loads] += 1
          if (waiting = fault.delete(:next_read_gate))
            waiting.entered << true
            waiting.release.pop
          end
        end
        original.call(execution_id)
      end
  end

  def start_unknown(**options)
    @original = @agent.invoke_async("perform the action once", **options)
    await_unknown
  end

  def await_unknown
    error = nil
    expect { result_of(@original) }.to raise_error(Phronomy::Agent::TerminalRecoveryError) { |caught| error = caught }
    @recovery = error.recovery
    @execution_id = error.execution_id
    @fault[:observing] = true
    expect(error.agent_id).to eq(@agent.agent_id)
    expect(error.recovery_id).to eq(@recovery.recovery_id)
    expect(@agent.pending_terminal_recovery(execution_id: @execution_id)).to equal(@recovery)
    expect(@registry.agent_execution_admitted?(@agent.agent_id)).to be(true)
    expect(@original.status).to eq(:failed)
    @original_error = error
  end

  def reconcile
    result_of(@agent.reconcile_terminal_async(recovery: @recovery))
  end

  def retry_save
    result_of(@agent.retry_terminal_async(recovery: @recovery))
  end

  def expect_retained(value, outcome:)
    expect(value.outcome).to eq(outcome)
    expect(value.application_state).to eq(:pending)
    expect(value.ownership_state).to eq(:retained)
    expect(@registry.agent_execution_admitted?(@agent.agent_id)).to be(true)
    expect(@agent.pending_terminal_recovery(execution_id: @execution_id)).to equal(@recovery)
  end

  def expect_released(value, status: :completed)
    expect(value.outcome).to eq(:confirmed_post)
    expect(value.application_state).to eq(:applied)
    expect(value.ownership_state).to eq(:released)
    expect(value.execution).to be_a(Phronomy::Agent::ExecutionObservation)
    expect(value.execution.status).to eq(status)
    expect(value.execution.execution_id).to eq(@execution_id)
    expect(@registry.agent_execution_admitted?(@agent.agent_id)).to be(false)
    expect(@agent.pending_terminal_recovery(execution_id: @execution_id)).to be_nil
    expect(@original.status).to eq(:failed)
    expect { result_of(@original) }.to raise_error { |error| expect(error).to equal(@original_error) }
  end

  def block_read
    gate.tap { |value| @fault[:next_read_gate] = value }
  end

  def block_owner_then_fail
    waiting = gate
    receiver = Object.new
    receiver.define_singleton_method(:deliver_on_event_loop) do |_command|
      waiting.entered << true
      waiting.release.pop
      raise IOError, "injected original owner failure"
    end
    expect(@registry.post(Struct.new(:coordinator).new(receiver))).to be(true)
    take(waiting.entered)
    waiting
  end

  def on_owner(&action)
    done = Queue.new
    receiver = Object.new
    receiver.define_singleton_method(:deliver_on_event_loop) do |_command|
      action.call
      done << true
    end
    expect(@registry.post(Struct.new(:coordinator).new(receiver))).to be(true)
    take(done)
  end

  def journal
    @store.journals.read(@agent.agent_id, after: 0).map(&:to_h)
  end

  def assert_no_record_writes
    expect_any_instance_of(Phronomy::Persistence::ContentRepository).not_to receive(:put)
    expect_any_instance_of(Phronomy::Agent::Persistence::JournalRepository).not_to receive(:append)
    expect_any_instance_of(Phronomy::Agent::Persistence::ExecutionRepository).not_to receive(:save)
    expect_any_instance_of(Phronomy::Agent::Persistence::AgentRepository).not_to receive(:save)
  end

  after do
    @validation_trace&.disable
    @gates&.each { |value| value.release << true }
    @shutdown_thread&.join(3)
    @runtime&.shutdown(timeout: 0.03, cancel_grace: 0.2)
  end

  it "applies a later confirmed commit to the original owner and permits the next invocation" do
    setup_agent
    start_unknown
    durable_journal = journal
    expect(@agent.agent_root.lifecycle_status).to eq(:active)
    expect(@events.count { |event| event.type == :done }).to eq(0)

    recovered = reconcile

    expect_released(recovered)
    expect(recovered.execution.result).to eq("retained answer")
    expect(@agent.agent_root.lifecycle_status).to eq(:idle)
    expect(journal).to eq(durable_journal)
    expect(@counts[:provider]).to eq(1)
    expect(@events.count { |event| event.type == :done }).to eq(0)
    expect(@original.physical_complete?).to be(true)
    next_result = result_of(@agent.invoke_async("next independent request"))
    expect(next_result.fetch(:output)).to eq("next answer")
    expect(@counts[:provider]).to eq(2)
  end

  it "retains confirmed pre-state and retries only captured content and records after real Tool work" do
    setup_agent(mode: :pre, tools: true, response: '{"answer":"retained answer"}')
    schema = {type: "object", properties: {answer: {type: "string"}}, required: ["answer"], additionalProperties: false}
    @parser_trace = TracePoint.new(:call) do |event|
      @counts[:parse] += 1 if event.defined_class == Phronomy::OutputParser::JsonSchemaParser && event.method_id == :parse
    end
    @parser_trace.enable
    allow(Phronomy::Agent::RuntimeRecordEncoder).to receive(:encode).and_wrap_original do |original, *args, **keywords|
      @counts[:terminal_encode] += 1 if @fault[:terminal]
      original.call(*args, **keywords)
    end
    start_unknown(output_schema: schema)
    expected_counts = {provider: 2, tool: 1, parse: 1, terminal_encode: 1, initial_terminal_transaction: 1}
    expect(@counts).to eq(expected_counts)
    original_journal = journal

    before_retry = reconcile

    expect_retained(before_retry, outcome: :confirmed_pre)
    expect(before_retry.execution).to be_nil
    expect(journal).to eq(original_journal)
    expect(@store.executions.load(@execution_id).status).to eq(:active)
    recovered = retry_save
    expect_released(recovered)
    expect(recovered.execution.result).to eq("answer" => "retained answer")
    expect(@counts).to eq(expected_counts)
    terminal = @store.executions.load(@execution_id)
    expect(@store.contents.exist?(terminal.result_ref)).to be(true)
    persisted = journal
    expect(persisted.length).to be > original_journal.length
    again = retry_save
    expect_released(again)
    expect(journal).to eq(persisted)
    expect(@counts).to eq(expected_counts)
  ensure
    @parser_trace&.disable
  end

  it "does not cache confirmed pre-state after cancellation changes the complete proof" do
    setup_agent(mode: :pre)
    start_unknown
    expect_retained(reconcile, outcome: :confirmed_pre)
    before = journal
    @store.request_cancellation(agent_id: @agent.agent_id, execution_id: @execution_id)
    loads = @fault[:recovery_loads]
    assert_no_record_writes

    changed = reconcile
    refused = retry_save

    expect_retained(changed, outcome: :unresolved)
    expect_retained(refused, outcome: :unresolved)
    expect(@fault[:recovery_loads]).to be > loads
    expect(@store.executions.load(@execution_id).status).to eq(:active)
    expect(journal).to eq(before)
    expect(@counts[:provider]).to eq(1)
  end

  it "does not repeat live journal application or terminal callbacks for released receipts" do
    setup_agent
    start_unknown
    first = reconcile
    before = journal
    loads = @fault[:recovery_loads]
    assert_no_record_writes

    second = @agent.reconcile_terminal(recovery: @recovery)
    third = @agent.retry_terminal(recovery: @recovery)

    [first, second, third].each { |value| expect_released(value) }
    expect(second).not_to equal(first)
    expect(second.execution).to be_frozen
    expect(second.execution).to eq(first.execution)
    expect(journal).to eq(before)
    expect(@fault[:recovery_loads]).to eq(loads)
    expect(@events.count { |event| event.type == :done }).to eq(0)
  end

  [Phronomy::Error, Phronomy::CancellationError].each do |error_class|
    it "preserves #{error_class} terminal meaning across rollback and save-only retry" do
      original_error = error_class.new("original terminal failure")
      setup_agent(mode: :pre, provider_error: original_error)
      start_unknown
      expect_retained(reconcile, outcome: :confirmed_pre)

      result = retry_save

      expect_released(result, status: (error_class == Phronomy::CancellationError) ? :cancelled : :failed)
      expect(result.error).to be_nil
      expect(result.execution.error.fetch("class")).to eq(error_class.name)
      expect(@events.none? { |event| %i[error cancelled].include?(event.type) }).to be(true)
      expect(@counts[:provider]).to eq(1)
    end
  end

  it "preserves output-validation failure without rerunning validation during recovery" do
    setup_agent(mode: :pre, response: "invalid structured output")
    schema = {type: "object", properties: {answer: {type: "string"}}, required: ["answer"]}
    validation_error = nil
    calls = 0
    @validation_trace = TracePoint.new(:call, :raise) do |event|
      if event.event == :call && event.defined_class == Phronomy::Agent::OutputContract && event.method_id == :validate
        calls += 1
      elsif event.event == :raise && event.raised_exception.is_a?(Phronomy::Agent::OutputError)
        validation_error = event.raised_exception
      end
    end
    @validation_trace.enable
    start_unknown(output_schema: schema)

    result = retry_save

    expect_released(result, status: :failed)
    expect(validation_error).to be_a(Phronomy::Agent::OutputError)
    expect(@events.none? { |event| event.type == :error }).to be(true)
    expect(result.execution.error.fetch("class")).to eq(Phronomy::Agent::OutputError.name)
    expect(calls).to eq(1)
    expect(@counts[:provider]).to eq(1)
  end

  it "coalesces same-kind observations while cancelling one observer leaves its owned read intact" do
    setup_agent
    start_unknown
    waiting = block_read
    first = @agent.reconcile_terminal_async(recovery: @recovery)
    take(waiting.entered)
    second = @agent.reconcile_terminal_async(recovery: @recovery)
    first.cancel!
    expect(first.status).to eq(:cancelled)
    waiting.release << true

    recovered = result_of(second)

    expect_released(recovered)
    expect(@fault[:recovery_loads]).to eq(1)
    expect { result_of(first) }.to raise_error(Phronomy::CancellationError)
    expect(@counts[:provider]).to eq(1)
  end

  it "does not turn an in-flight read into a write for a concurrent retry request" do
    setup_agent(mode: :pre)
    start_unknown
    before = journal
    waiting = block_read
    first = @agent.reconcile_terminal_async(recovery: @recovery)
    take(waiting.entered)
    retrying = @agent.retry_terminal_async(recovery: @recovery)

    expect_retained(result_of(retrying), outcome: :unavailable)
    waiting.release << true
    expect_retained(result_of(first), outcome: :confirmed_pre)
    expect(journal).to eq(before)
    expect(@store.executions.load(@execution_id).status).to eq(:active)
    expect_released(retry_save)
  end

  it "retains finished evidence when recovery Ready delivery is refused" do
    setup_agent
    start_unknown
    allow(@registry).to receive(:post).and_wrap_original do |original, command, **options|
      if command.is_a?(Phronomy::Agent::TerminalRecoveryOperation::Ready) && command.attempt_id
        false
      else
        original.call(command, **options)
      end
    end

    refused = reconcile

    expect_retained(refused, outcome: :unavailable)
    reads = @fault[:recovery_loads]
    allow(@registry).to receive(:post).and_call_original
    expect_released(reconcile)
    expect(@fault[:recovery_loads]).to eq(reads)
    expect(@counts[:provider]).to eq(1)
  end

  it "reports recovery for an initial Ready refusal and later applies the successful save" do
    setup_agent
    allow(@registry).to receive(:post).and_wrap_original do |original, command, **options|
      if command.is_a?(Phronomy::Agent::TerminalRecoveryOperation::Ready) && command.attempt_id.nil?
        false
      else
        original.call(command, **options)
      end
    end
    start_unknown
    allow(@registry).to receive(:post).and_call_original

    expect_released(reconcile)

    expect(@counts[:provider]).to eq(1)
    expect(@events.count { |event| event.type == :done }).to eq(0)
  end

  it "rejects a different Agent incarnation even when its durable identifier matches" do
    setup_agent
    start_unknown
    impostor = @agent.dup
    before = @fault[:recovery_loads]

    expect { impostor.reconcile_terminal_async(recovery: @recovery) }.to raise_error(ArgumentError)
    expect { impostor.retry_terminal(recovery: @recovery) }.to raise_error(ArgumentError)
    expect { @agent.reconcile_terminal(recovery: Object.new) }.to raise_error(ArgumentError)
    expect(impostor.pending_terminal_recovery(execution_id: @execution_id)).to be_nil
    expect(@fault[:recovery_loads]).to eq(before)
    expect_released(reconcile)
  end

  it "retains responsibility across incomplete shutdown without selecting another Runtime" do
    setup_agent
    start_unknown
    before = @fault[:recovery_loads]

    shutdown = @runtime.shutdown(timeout: 0.02, cancel_grace: 0.2)

    expect(shutdown.cleanup_complete?).to be(false)
    expect_retained(reconcile, outcome: :unavailable)
    expect(@fault[:recovery_loads]).to eq(before)
    expect(@runtime.shutdown(timeout: 0).cleanup_complete?).to be(false)
    expect(Phronomy::Runtime.instance).to equal(@runtime)
  end

  it "finishes an accepted recovery during drain before reporting complete shutdown" do
    setup_agent
    start_unknown
    finished = Queue.new
    @shutdown_thread = Thread.new { finished << @runtime.shutdown(timeout: 2, cancel_grace: 0.2) }
    eventually { @runtime.state == :draining }

    expect_released(reconcile)
    expect(take(finished).cleanup_complete?).to be(true)
    expect(@shutdown_thread.join(1)).to equal(@shutdown_thread)
  end

  it "delivers ordinary completion exactly once and does not retain unnecessary recovery" do
    setup_agent(mode: :none)
    original = @agent.invoke_async("ordinary request")

    value = result_of(original)

    expect(value.fetch(:output)).to eq("retained answer")
    expect(@events.count { |event| event.type == :done }).to eq(1)
    expect(@agent.pending_terminal_recovery(execution_id: value.fetch(:execution_id))).to be_nil
    expect(@registry.agent_execution_admitted?(@agent.agent_id)).to be(false)
    expect(original.physical_complete?).to be(true)
  end

  it "returns the actual output-contract exception on an ordinary failed terminal completion" do
    setup_agent(mode: :none, response: "invalid structured output")
    validation_error = nil
    @validation_trace = TracePoint.new(:raise) do |event|
      validation_error = event.raised_exception if event.raised_exception.is_a?(Phronomy::Agent::OutputError)
    end
    @validation_trace.enable
    schema = {type: "object", properties: {answer: {type: "string"}}, required: ["answer"]}
    original = @agent.invoke_async("ordinary invalid output", output_schema: schema)

    expect { result_of(original) }.to raise_error(Phronomy::Agent::OutputError) do |error|
      expect(error).to equal(validation_error)
      expect(error.cause).to be_a(Phronomy::ParseError)
    end

    expect(@events.count { |event| event.type == :error }).to eq(1)
    expect(@events.find { |event| event.type == :error }.payload.fetch(:error)).to equal(validation_error)
    expect(@registry.agent_execution_admitted?(@agent.agent_id)).to be(false)
  end

  it "does not overlap reads after a real Offload timeout while the first worker is still running" do
    setup_agent
    start_unknown
    pool = @runtime.offload
    allow(pool).to receive(:submit).and_wrap_original do |original, **options, &work|
      original.call(**options.merge(timeout: 0.02), &work)
    end
    waiting = block_read
    first = @agent.reconcile_terminal_async(recovery: @recovery)
    take(waiting.entered)
    eventually { pool.abandoned_active_count == 1 }
    second = @agent.reconcile_terminal_async(recovery: @recovery)
    expect { first.wait_result(timeout: 0.01) }.to raise_error(Phronomy::TimeoutError)
    expect(@fault[:recovery_loads]).to eq(1)
    expect(@registry.agent_execution_admitted?(@agent.agent_id)).to be(true)
    waiting.release << true

    expect_released(result_of(first))
    expect_released(result_of(second))
    expect(@fault[:recovery_loads]).to eq(1)
    expect(@counts[:provider]).to eq(1)
  end

  it "retains the original save's physical boundary after a real Offload timeout" do
    setup_agent
    pool = @runtime.offload
    waiting = gate
    @fault[:next_save_gate] = waiting
    allow_any_instance_of(Phronomy::Agent::TerminalRecoveryOperation).to receive(:start).and_wrap_original do |original, *args, **options|
      allow(pool).to receive(:submit).and_wrap_original do |submit, **keywords, &work|
        submit.call(**keywords.merge(timeout: 0.02), &work)
      end
      original.call(*args, **options)
    end
    @original = @agent.invoke_async("ordinary request")
    take(waiting.entered)
    eventually { pool.abandoned_active_count == 1 }
    await_unknown
    before = @fault[:recovery_loads]

    expect_retained(reconcile, outcome: :unavailable)
    expect_retained(retry_save, outcome: :unavailable)
    expect(@fault[:recovery_loads]).to eq(before)
    expect(@original.physical_complete?).to be(false)
    allow(pool).to receive(:submit).and_call_original
    waiting.release << true
    eventually { pool.abandoned_active_count.zero? }
    expect_released(reconcile)
    expect(@original.physical_complete?).to be(true)
    expect(@events.none? { |event| %i[done error cancelled].include?(event.type) }).to be(true)
  end

  it "keeps the original save when completion callback registration raises after admission" do
    setup_agent
    waiting = gate
    @fault[:next_save_gate] = waiting
    admitted = Queue.new
    allow_any_instance_of(Phronomy::Agent::TerminalRecoveryOperation).to receive(:start).and_wrap_original do |original, *args, **options|
      environment = @agent.__execution_environment
      allow(environment).to receive(:submit).and_wrap_original do |submit, **keywords, &work|
        submit.call(**keywords, &work).tap do |task|
          allow(task).to receive(:on_complete).and_raise(IOError.new("completion registration failed after admission"))
          admitted << task
        end
      end
      original.call(*args, **options)
    end
    @original = @agent.invoke_async("ordinary request")
    task = take(admitted)
    take(waiting.entered)
    await_unknown

    expect_retained(reconcile, outcome: :unavailable)
    expect(task.physical_complete?).to be(false)
    expect(@original.physical_complete?).to be(false)
    expect(admitted.empty?).to be(true)
    allow(@agent.__execution_environment).to receive(:submit).and_call_original
    waiting.release << true
    eventually { task.physical_complete? }
    expect_released(reconcile)
    expect(@original.physical_complete?).to be(true)
  end

  it "keeps an admitted read when completion callback registration raises and joins its physical lane" do
    setup_agent
    start_unknown
    waiting = block_read
    admitted = Queue.new
    environment = @agent.__execution_environment
    allow(environment).to receive(:submit).and_wrap_original do |submit, **options, &work|
      submit.call(**options, &work).tap do |task|
        allow(task).to receive(:on_complete).and_raise(IOError.new("read completion registration failed"))
        admitted << task
      end
    end
    first = @agent.reconcile_terminal_async(recovery: @recovery)
    task = take(admitted)
    take(waiting.entered)

    expect_retained(result_of(first), outcome: :unavailable)
    second = @agent.reconcile_terminal_async(recovery: @recovery)
    expect { second.wait_result(timeout: 0.01) }.to raise_error(Phronomy::TimeoutError)
    expect(admitted.empty?).to be(true)
    expect(@fault[:recovery_loads]).to eq(1)
    waiting.release << true
    eventually { task.physical_complete? }
    expect_released(result_of(second))
    expect(@fault[:recovery_loads]).to eq(1)
  end

  it "retains responsibility after recovery submission rejection and accepts a later explicit retry" do
    setup_agent
    start_unknown
    environment = @agent.__execution_environment
    allow(environment).to receive(:submit).and_raise(Phronomy::BackpressureError.new("recovery read rejected"))

    expect_retained(reconcile, outcome: :unavailable)
    expect(@fault[:recovery_loads]).to eq(0)
    allow(environment).to receive(:submit).and_call_original
    expect_released(reconcile)
  end

  it "keeps the old receipt from releasing a newer invocation on the same Agent" do
    setup_agent
    start_unknown
    expect_released(reconcile)
    old_recovery = @recovery
    waiting = gate
    allow(@adapter).to receive(:perform_complete).and_wrap_original do |original, *args, **options|
      waiting.entered << true
      waiting.release.pop
      original.call(*args, **options)
    end
    fresh = @agent.invoke_async("new independent request")
    take(waiting.entered)
    new_root = @agent.agent_root
    reads = @fault[:recovery_loads]

    repeated = @agent.reconcile_terminal(recovery: old_recovery)

    expect(repeated.ownership_state).to eq(:released)
    expect(@registry.agent_execution_admitted?(@agent.agent_id)).to be(true)
    expect(@agent.agent_root).to equal(new_root)
    expect(fresh.status).to eq(:pending)
    expect(@fault[:recovery_loads]).to eq(reads)
    waiting.release << true
    expect(result_of(fresh).fetch(:output)).to eq("next answer")
  end

  it "rejects contradictory public recovery facts and preserves independent error causes" do
    setup_agent
    start_unknown
    values = {recovery: @recovery, outcome: :confirmed_pre, application_state: :pending, ownership_state: :retained}
    expect { Phronomy::Agent::TerminalRecovery.new(Object.new) }.to raise_error(NoMethodError)
    expect { Phronomy::Agent::TerminalRecoveryResult.new(**values.merge(application_state: :applied, ownership_state: :released)) }
      .to raise_error(ArgumentError)
    expect { Phronomy::Agent::TerminalRecoveryResult.new(**values.merge(outcome: :confirmed_post, revision: 0)) }
      .to raise_error(ArgumentError)
    expect { Phronomy::Agent::TerminalRecoveryResult.new(**values.merge(ownership_state: :released)) }
      .to raise_error(ArgumentError)
    wrong_execution = Phronomy::Agent::ExecutionObservation.new(agent_id: @agent.agent_id,
      execution_id: "another-execution", status: :completed, result: "answer", error: nil,
      reservation: nil, transfer_receipt: nil, cancellation_requested: false)
    expect { Phronomy::Agent::TerminalRecoveryResult.new(**values.merge(outcome: :confirmed_post, revision: 2, execution: wrong_execution)) }
      .to raise_error(ArgumentError)
    expect { Phronomy::Agent::TerminalRecoveryResult.new(**values.merge(revision: 1)) }
      .to raise_error(ArgumentError)
    original = IOError.new("original save error")
    immediate = IOError.new("later read error")
    error = Phronomy::Agent::TerminalRecoveryError.new(recovery: @recovery, error: immediate, original_error: original)
    task = Phronomy::TaskResult.failed(error)
    expect { result_of(task) }.to raise_error do |caught|
      expect(caught.original_error).to equal(original)
      expect(caught.cause).to equal(immediate)
    end
    expect_released(reconcile)
  end

  it "settles a queued observation when the original owner fails before dispatch" do
    setup_agent
    start_unknown
    waiting = block_owner_then_fail
    observer = @agent.reconcile_terminal_async(recovery: @recovery)
    expect(observer.status).to eq(:pending)
    waiting.release << true
    eventually { @runtime.state == :failed }

    expect_retained(result_of(observer), outcome: :unavailable)
    expect(@fault[:recovery_loads]).to eq(0)
  end

  it "retains custody when Ready was accepted but the owner fails before applying it" do
    setup_agent
    start_unknown
    read_gate = block_read
    observer = @agent.reconcile_terminal_async(recovery: @recovery)
    take(read_gate.entered)
    owner_gate = block_owner_then_fail
    accepted = Queue.new
    allow(@registry).to receive(:post).and_wrap_original do |original, command, **options|
      original.call(command, **options).tap do |value|
        if value && command.is_a?(Phronomy::Agent::TerminalRecoveryOperation::Ready) && command.attempt_id
          accepted << true
        end
      end
    end
    read_gate.release << true
    take(accepted)
    expect(observer.status).to eq(:pending)
    owner_gate.release << true
    eventually { @runtime.state == :failed }

    expect_retained(result_of(observer), outcome: :unavailable)
    expect(@agent.agent_root.lifecycle_status).to eq(:active)
    expect(@fault[:recovery_loads]).to eq(1)
  end

  it "refuses live application when the saved proof returns to a different session identity" do
    setup_agent
    start_unknown
    waiting = block_read
    observer = @agent.reconcile_terminal_async(recovery: @recovery)
    take(waiting.entered)
    previous_root = @agent.agent_root
    on_owner do
      @registry.replace_agent_execution(@execution_id, fsm_session_id: "replacement-session")
    end
    waiting.release << true

    value = result_of(observer)

    expect(value.outcome).to eq(:confirmed_post)
    expect(value.application_state).to eq(:pending)
    expect(value.ownership_state).to eq(:retained)
    expect(value.error).not_to be_nil
    expect(@agent.agent_root).to equal(previous_root)
    expect(@registry.agent_execution_admitted?(@agent.agent_id)).to be(true)
  end

  it "recovers after physical-completion subscription fails without leaking the original task's lifetime" do
    setup_agent
    waiting = gate
    @fault[:next_save_gate] = waiting
    admitted = Queue.new
    allow_any_instance_of(Phronomy::Agent::TerminalRecoveryOperation).to receive(:start).and_wrap_original do |original, *args, **options|
      environment = @agent.__execution_environment
      allow(environment).to receive(:submit).and_wrap_original do |submit, **keywords, &work|
        submit.call(**keywords, &work).tap do |task|
          allow(task).to receive(:on_physical_complete).and_raise(IOError.new("physical completion registration failed"))
          admitted << task
        end
      end
      original.call(*args, **options)
    end
    @original = @agent.invoke_async("ordinary request")
    task = take(admitted)
    take(waiting.entered)
    await_unknown

    expect_retained(reconcile, outcome: :unavailable)
    expect(task.physical_complete?).to be(false)
    expect(@original.physical_complete?).to be(false)
    allow(@agent.__execution_environment).to receive(:submit).and_call_original
    waiting.release << true
    eventually { task.physical_complete? }
    expect_released(reconcile)
    expect(@original.physical_complete?).to be(true)
  end

  it "retries a partial live application without appending the captured journal twice" do
    setup_agent
    start_unknown
    failure_pending = true
    allow(@agent).to receive(:__replace_root).and_wrap_original do |original, root|
      if failure_pending
        failure_pending = false
        raise IOError, "live root replacement failed after journal application"
      end
      original.call(root)
    end
    first = reconcile
    reads = @fault[:recovery_loads]
    partially_applied_journal = @agent.send(:_journal_records_snapshot)

    expect_retained(first, outcome: :confirmed_post)
    expect(first.error).not_to be_nil
    expect_released(reconcile)
    expect(@agent.send(:_journal_records_snapshot)).to eq(partially_applied_journal)
    expect(@fault[:recovery_loads]).to eq(reads)
    expect(@events.none? { |event| %i[done error cancelled].include?(event.type) }).to be(true)
  end

  it "retries only release after live application succeeded but custody release was refused" do
    setup_agent
    start_unknown
    release_pending = true
    allow(@registry).to receive(:release_terminal_operation).and_wrap_original do |original, operation|
      if release_pending
        release_pending = false
        false
      else
        original.call(operation)
      end
    end
    first = reconcile
    reads = @fault[:recovery_loads]
    applied_journal = @agent.send(:_journal_records_snapshot)

    expect(first.outcome).to eq(:confirmed_post)
    expect(first.application_state).to eq(:applied)
    expect(first.ownership_state).to eq(:retained)
    expect(first.error).not_to be_nil
    expect(@registry.agent_execution_admitted?(@agent.agent_id)).to be(true)
    expect_released(reconcile)
    expect(@agent.send(:_journal_records_snapshot)).to eq(applied_journal)
    expect(@fault[:recovery_loads]).to eq(reads)
    expect(@counts[:provider]).to eq(1)
  end

  it "rejects synchronous recovery waits on the original EventLoop before persistence I/O" do
    setup_agent
    start_unknown
    failures = []
    before = @fault[:recovery_loads]
    on_owner do
      [:reconcile_terminal, :retry_terminal].each do |method|
        @agent.public_send(method, recovery: @recovery)
      rescue => error
        failures << error
      end
    end

    expect(failures.length).to eq(2)
    expect(failures).to all(be_a(Phronomy::EventLoopReentrancyError))
    expect(@fault[:recovery_loads]).to eq(before)
    expect_released(reconcile)
  end
end
