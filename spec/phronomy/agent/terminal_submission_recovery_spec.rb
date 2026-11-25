# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe "Agent terminal submission recovery through the original Runtime" do
  SubmissionGate = Struct.new(:entered, :release)

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
    SubmissionGate.new(entered: Queue.new, release: Queue.new).tap { |value| (@gates ||= []) << value }
  end

  def setup_agent
    @counts = counts = Hash.new(0)
    tool_class = Class.new(Phronomy::Tool::Base) do
      tool_name "terminal_submission_tool"
      description "Performs the original authorized action"
      param :value, type: :string, desc: "Action input"
      define_method(:execute) do |value:|
        counts[:tool] += 1
        "observed #{value}"
      end
    end
    replies = [
      Phronomy::LLMAdapter::Response.new(finish_reason: :tool_calls, tool_calls: [
        Phronomy::Tool::CallRequest.new(id: "submission-call", name: "terminal_submission_tool", arguments: {value: "once"})
      ]),
      Phronomy::LLMAdapter::Response.new(content: '{"answer":"captured answer"}', finish_reason: :stop)
    ]
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |_request, cancellation_token:|
        cancellation_token&.raise_if_cancelled!
        counts[:provider] += 1
        replies.shift || raise("Provider was replayed after its original result")
      end
    end.new
    Phronomy.configure do |configuration|
      configuration.offload_pool_size = 1
      configuration.offload_queue_size = 1
      configuration.llm_adapter = adapter
    end
    @runtime = Phronomy::Runtime.instance
    @registry = Phronomy::Agent::ExecutionRegistry.for(@runtime.event_loop)
    @store = Phronomy::PersistenceComposition.in_memory.agent
    @agent_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "terminal-submission-runtime", version: 1
      tools tool_class => nil
    end
    @events = []
    @agent = @agent_class.create(agent_id: "terminal-submission-#{RSpec.current_example.metadata.fetch(:line_number)}",
      persistence: @store, on_event: ->(event) { @events << event })
    @terminal_gate = gate
    allow_any_instance_of(Phronomy::Agent::ExecutionCoordinator)
      .to receive(:submit_terminal_operation).and_wrap_original do |original, operation, delivery|
        @terminal_gate.entered << operation
        @terminal_gate.release.pop
        original.call(operation, delivery)
      end
    allow_any_instance_of(Phronomy::Agent::ExecutionOutcomeCommitter)
      .to receive(:commit_outcome).and_wrap_original do |original, operation, **options|
        @counts[:committer] += 1
        @in_terminal_worker = true
        original.call(operation, **options)
      ensure
        @in_terminal_worker = false
      end
    allow(Phronomy::Agent::RuntimeRecordEncoder).to receive(:encode).and_wrap_original do |original, *args, **options|
      @counts[:terminal_encode] += 1 if @in_terminal_worker
      original.call(*args, **options)
    end
    @parser_trace = TracePoint.new(:call) do |event|
      @counts[:parse] += 1 if event.defined_class == Phronomy::OutputParser::JsonSchemaParser && event.method_id == :parse
    end
    @parser_trace.enable
  end

  # The held EventLoop boundary only makes pool saturation deterministic. The
  # real bounded OffloadPool performs queue admission and raises BackpressureError.
  def start_with_rejected_terminal
    schema = {type: "object", properties: {answer: {type: "string"}}, required: ["answer"], additionalProperties: false}
    @original = @agent.invoke_async("perform the action once", output_schema: schema)
    @command = take(@terminal_gate.entered)
    @saturation = saturate_pool
    @terminal_gate.release << true
    expect { result_of(@original) }.to raise_error(Phronomy::Agent::TerminalRecoveryError) do |error|
      @original_error = error
      @recovery = error.recovery
      @execution_id = error.execution_id
    end
    expect(@original_error.cause).to be_a(Phronomy::BackpressureError)
    expect(@counts).to eq(provider: 2, tool: 1)
    expect(@store.executions.load(@execution_id).status).to eq(:active)
    expect(@agent.pending_terminal_recovery(execution_id: @execution_id)).to equal(@recovery)
    expect(@events.none? { |event| %i[done error cancelled].include?(event.type) }).to be(true)
  end

  def occupy_worker
    waiting = gate
    task = @runtime.offload.submit(on_full: :raise) do
      waiting.entered << true
      waiting.release.pop
    end
    take(waiting.entered)
    [waiting, task]
  end

  def saturate_pool
    waiting, running = occupy_worker
    queued = @runtime.offload.submit(on_full: :raise) { :filler }
    expect(@runtime.offload.queue_depth).to eq(1)
    [waiting, running, queued]
  end

  def release_saturation
    return unless @saturation
    waiting, running, queued = @saturation
    waiting.release << true
    result_of(running)
    result_of(queued)
    @saturation = nil
    eventually { @runtime.offload.queue_depth.zero? && @runtime.offload.active_count.zero? }
  end

  def submit_again
    result_of(@agent.retry_terminal_submission_async(recovery: @recovery))
  end

  def expect_retained(value, outcome: :unavailable)
    expect(value.outcome).to eq(outcome)
    expect(value.application_state).to eq(:pending)
    expect(value.ownership_state).to eq(:retained)
    expect(@agent.pending_terminal_recovery(execution_id: @execution_id)).to equal(@recovery)
    expect(@registry.agent_execution_admitted?(@agent.agent_id)).to be(true)
    expect(@original.status).to eq(:failed)
  end

  def expect_released(value)
    expect(value.outcome).to eq(:confirmed_post)
    expect(value.application_state).to eq(:applied)
    expect(value.ownership_state).to eq(:released)
    expect(value.submission_state).to eq(:admitted)
    expect(value.execution.result).to eq("answer" => "captured answer")
    expect(@registry.agent_execution_admitted?(@agent.agent_id)).to be(false)
    expect(@agent.pending_terminal_recovery(execution_id: @execution_id)).to be_nil
    expect(@events.none? { |event| %i[done error cancelled].include?(event.type) }).to be(true)
    expect { result_of(@original) }.to raise_error { |error| expect(error).to equal(@original_error) }
  end

  after do
    @parser_trace&.disable
    @gates&.each { |value| value.release << true }
    @shutdown_thread&.join(3)
    @runtime&.shutdown(timeout: 0.03, cancel_grace: 0.2)
  end

  it "submits the terminal work for the first time after an actual full-pool rejection" do
    setup_agent
    start_with_rejected_terminal
    release_saturation
    expect_retained(@agent.reconcile_terminal(recovery: @recovery))
    expect_retained(@agent.retry_terminal(recovery: @recovery))
    expect(@counts).to eq(provider: 2, tool: 1)

    expect_released(submit_again)

    expect(@counts).to eq(provider: 2, tool: 1, committer: 1, parse: 1, terminal_encode: 1)
  end

  it "keeps terminal submission recoverable when the Tool finishes before callback registration" do
    setup_agent
    finished_worker = gate
    worker_paused = false
    allow(@runtime.offload).to receive(:run_operation).and_wrap_original do |original, operation|
      result = original.call(operation)
      if @counts[:provider] == 1 && @counts[:tool] == 1 && !worker_paused
        worker_paused = true
        finished_worker.entered << true
        finished_worker.release.pop
      end
      result
    end
    allow_any_instance_of(Phronomy::Agent::ToolInvocation)
      .to receive(:start_async_tool_operation).and_wrap_original do |original, environment|
        task = original.call(environment)
        take(finished_worker.entered)
        expect(task.done?).to be(true)
        task
      end
    allow_any_instance_of(Phronomy::Agent::ExecutionCoordinator)
      .to receive(:submit_provider_dispatch_preparation).and_wrap_original do |original, operation|
        original.call(operation)
      ensure
        if @counts[:provider] == 1 && @counts[:tool] == 1
          finished_worker.release << true
        end
      end

    # A settled Tool invokes its completion callback on the EventLoop. Tracing
    # finish must leave the business queue slot for the next provider dispatch.
    start_with_rejected_terminal
    release_saturation
    expect_released(submit_again)

    expect(@counts).to eq(provider: 2, tool: 1, committer: 1, parse: 1, terminal_encode: 1)
  end

  it "permits another explicit request after repeated proven full-pool refusals" do
    setup_agent
    start_with_rejected_terminal

    first = submit_again
    second = submit_again

    [first, second].each do |value|
      expect_retained(value)
      expect(value.submission_state).to eq(:not_admitted)
    end
    expect(@counts).to eq(provider: 2, tool: 1)
    release_saturation
    expect_released(@agent.retry_terminal_submission(recovery: @recovery))
    expect(@counts).to eq(provider: 2, tool: 1, committer: 1, parse: 1, terminal_encode: 1)
  end

  it "treats queued work as admitted, coalesces peers and keeps observer cancellation independent" do
    setup_agent
    start_with_rejected_terminal
    release_saturation
    waiting, occupied = occupy_worker
    first = @agent.retry_terminal_submission_async(recovery: @recovery)
    eventually { @runtime.offload.queue_depth == 1 }
    first.cancel!
    second = @agent.retry_terminal_submission_async(recovery: @recovery)

    read = @agent.reconcile_terminal(recovery: @recovery)
    retrying = @agent.retry_terminal(recovery: @recovery)
    [read, retrying].each do |value|
      expect_retained(value)
      expect(value.submission_state).to eq(:admitted)
    end
    expect(@counts).to eq(provider: 2, tool: 1)
    expect(@runtime.offload.queue_depth).to eq(1)
    waiting.release << true
    result_of(occupied)
    expect_released(result_of(second))
    expect { result_of(first) }.to raise_error(Phronomy::CancellationError)
    expect(@counts).to eq(provider: 2, tool: 1, committer: 1, parse: 1, terminal_encode: 1)
  end

  it "consumes submission authority when queued work times out before its block starts" do
    setup_agent
    start_with_rejected_terminal
    release_saturation
    waiting, occupied = occupy_worker
    pool = @runtime.offload
    allow(pool).to receive(:submit).and_wrap_original do |original, **options, &work|
      original.call(**options.merge(timeout: 0.02), &work)
    end

    timed_out = submit_again

    expect_retained(timed_out)
    expect(timed_out.submission_state).to eq(:admitted)
    expect(@counts).to eq(provider: 2, tool: 1)
    allow(pool).to receive(:submit).and_call_original
    repeated = submit_again
    expect_retained(repeated)
    expect(repeated.submission_state).to eq(:admitted)
    expect(@runtime.offload.queue_depth).to eq(1)
    waiting.release << true
    result_of(occupied)
    eventually { pool.queue_depth.zero? && pool.active_count.zero? }
    expect_retained(submit_again)
    expect(@counts).to eq(provider: 2, tool: 1)
  end

  it "does not restore first-submission authority after an admitted encoder fails without a complete proof" do
    setup_agent
    start_with_rejected_terminal
    release_saturation
    failure = IOError.new("first terminal encoding failed before a complete proposal")
    allow(Phronomy::Agent::RuntimeRecordEncoder).to receive(:encode) do |*_, **_options|
      @counts[:terminal_encode] += 1
      raise failure
    end

    failed = submit_again

    expect_retained(failed)
    expect(failed.submission_state).to eq(:admitted)
    expect(@counts).to eq(provider: 2, tool: 1, committer: 1, parse: 1, terminal_encode: 1)
    expect_retained(submit_again)
    expect_retained(@agent.retry_terminal(recovery: @recovery))
    expect_retained(@agent.reconcile_terminal(recovery: @recovery))
    expect(@counts).to eq(provider: 2, tool: 1, committer: 1, parse: 1, terminal_encode: 1)
  end

  it "retains the admitted lane when completion registration fails before queued work starts" do
    setup_agent
    start_with_rejected_terminal
    release_saturation
    waiting, occupied = occupy_worker
    environment = @agent.__execution_environment
    accepted = Queue.new
    allow(environment).to receive(:submit).and_wrap_original do |original, **options, &work|
      original.call(**options, &work).tap do |task|
        allow(task).to receive(:on_complete).and_raise(IOError.new("completion registration failed after admission"))
        accepted << task
      end
    end
    first = @agent.retry_terminal_submission_async(recovery: @recovery)
    task = take(accepted)
    refused = result_of(first)

    expect_retained(refused)
    expect(refused.submission_state).to eq(:admitted)
    expect(task.physical_complete?).to be(false)
    expect(@counts).to eq(provider: 2, tool: 1)
    second = @agent.retry_terminal_submission_async(recovery: @recovery)
    expect { second.wait_result(timeout: 0.01) }.to raise_error(Phronomy::TimeoutError)
    expect(accepted.empty?).to be(true)
    allow(environment).to receive(:submit).and_call_original
    waiting.release << true
    result_of(occupied)
    expect_released(result_of(second))
    expect(@counts).to eq(provider: 2, tool: 1, committer: 1, parse: 1, terminal_encode: 1)
  end

  it "switches to captured-write retry after the first admitted proposal rolls back" do
    setup_agent
    start_with_rejected_terminal
    release_saturation
    fault = {armed: true, unreadable: false}
    allow(@store.coordinator).to receive(:atomic).and_wrap_original do |original, &transaction|
      if @in_terminal_worker && fault[:armed]
        fault[:armed] = false
        original.call do |scope|
          transaction.call(scope)
          fault[:unreadable] = true
          raise IOError, "first terminal transaction rolled back after proposal"
        end
      else
        original.call(&transaction)
      end
    end
    allow_any_instance_of(Phronomy::Agent::Persistence::ExecutionRepository)
      .to receive(:load).and_wrap_original do |original, execution_id|
        if fault[:unreadable]
          fault[:unreadable] = false
          raise IOError, "first terminal readback unavailable"
        end
        original.call(execution_id)
      end
    expect_retained(submit_again)
    expect_retained(submit_again)
    confirmed = @agent.reconcile_terminal(recovery: @recovery)
    expect_retained(confirmed, outcome: :confirmed_pre)
    expect(confirmed.submission_state).to eq(:admitted)

    expect_released(@agent.retry_terminal(recovery: @recovery))

    expect(@counts).to eq(provider: 2, tool: 1, committer: 1, parse: 1, terminal_encode: 1)
    before = @store.journals.read(@agent.agent_id, after: 0).map(&:to_h)
    expect_released(submit_again)
    expect(@store.journals.read(@agent.agent_id, after: 0).map(&:to_h)).to eq(before)
    expect(@counts).to eq(provider: 2, tool: 1, committer: 1, parse: 1, terminal_encode: 1)
  end

  it "does not infer non-admission from a custom wrapper that enqueues then raises BackpressureError" do
    setup_agent
    schema = {type: "object", properties: {answer: {type: "string"}}, required: ["answer"]}
    @original = @agent.invoke_async("perform the action once", output_schema: schema)
    @command = take(@terminal_gate.entered)
    waiting, occupied = occupy_worker
    accepted = Queue.new
    environment = @agent.__execution_environment
    allow(environment).to receive(:submit).and_wrap_original do |original, **options, &work|
      accepted << original.call(**options, &work)
      raise Phronomy::BackpressureError, "custom wrapper lost its admitted handle"
    end
    @terminal_gate.release << true
    task = take(accepted)
    expect { result_of(@original) }.to raise_error(Phronomy::Agent::TerminalRecoveryError) do |error|
      @original_error, @recovery, @execution_id = error, error.recovery, error.execution_id
    end
    allow(environment).to receive(:submit).and_call_original

    unknown = submit_again
    expect_retained(unknown)
    expect(unknown.submission_state).to eq(:unknown)
    expect(@original.physical_complete?).to be(false)
    expect(@runtime.offload.queue_depth).to eq(1)
    expect(@counts).to eq(provider: 2, tool: 1)
    waiting.release << true
    result_of(occupied)
    result_of(task)
    attempted = submit_again
    expect_retained(attempted)
    expect(attempted.submission_state).to eq(:admitted)
    expect(@original.physical_complete?).to be(false)
    expect(@counts).to eq(provider: 2, tool: 1, committer: 1, parse: 1, terminal_encode: 1)
  end

  it "keeps a stopped original owner unavailable without creating a replacement Runtime" do
    setup_agent
    start_with_rejected_terminal
    release_saturation

    shutdown = @runtime.shutdown(timeout: 0.02, cancel_grace: 0.2)

    expect(shutdown.cleanup_complete?).to be(false)
    stopped = submit_again
    expect_retained(stopped)
    expect(stopped.submission_state).to eq(:not_admitted)
    expect(@counts).to eq(provider: 2, tool: 1)
    expect(Phronomy::Runtime.instance).to equal(@runtime)
  end

  it "allows an accepted job's first terminal submission while the original Runtime drains" do
    setup_agent
    start_with_rejected_terminal
    release_saturation
    stopped = Queue.new
    @shutdown_thread = Thread.new { stopped << @runtime.shutdown(timeout: 2, cancel_grace: 0.2) }
    eventually { @runtime.state == :draining }

    expect_released(submit_again)

    expect(take(stopped).cleanup_complete?).to be(true)
    expect(@counts).to eq(provider: 2, tool: 1, committer: 1, parse: 1, terminal_encode: 1)
  end

  it "retains a running first submission across logical timeout without admitting another worker" do
    setup_agent
    start_with_rejected_terminal
    release_saturation
    waiting = gate
    allow(Phronomy::Agent::RuntimeRecordEncoder).to receive(:encode).and_wrap_original do |original, *args, **options|
      @counts[:terminal_encode] += 1
      waiting.entered << true
      waiting.release.pop
      original.call(*args, **options)
    end
    pool = @runtime.offload
    allow(pool).to receive(:submit).and_wrap_original do |original, **options, &work|
      original.call(**options.merge(timeout: 0.02), &work)
    end
    first = @agent.retry_terminal_submission_async(recovery: @recovery)
    take(waiting.entered)
    eventually { pool.abandoned_active_count == 1 }
    allow(pool).to receive(:submit).and_call_original
    second = @agent.retry_terminal_submission_async(recovery: @recovery)
    blocked = @agent.reconcile_terminal(recovery: @recovery)

    expect_retained(blocked)
    expect(blocked.submission_state).to eq(:admitted)
    expect { first.wait_result(timeout: 0.01) }.to raise_error(Phronomy::TimeoutError)
    expect(@counts).to eq(provider: 2, tool: 1, committer: 1, parse: 1, terminal_encode: 1)
    waiting.release << true
    expect_released(result_of(first))
    expect_released(result_of(second))
    expect(@counts).to eq(provider: 2, tool: 1, committer: 1, parse: 1, terminal_encode: 1)
  end

  it "keeps capability identity, admission facts and EventLoop waiting rules explicit" do
    setup_agent
    start_with_rejected_terminal
    release_saturation
    other_incarnation = @agent.dup
    expect { other_incarnation.retry_terminal_submission(recovery: @recovery) }.to raise_error(ArgumentError)
    expect { @agent.retry_terminal_submission_async(recovery: Object.new) }.to raise_error(ArgumentError)
    expect {
      Phronomy::Agent::TerminalRecoveryResult.new(recovery: @recovery, outcome: :confirmed_post,
        application_state: :pending, ownership_state: :retained, revision: 2, submission_state: :not_admitted)
    }.to raise_error(ArgumentError)
    received = Queue.new
    receiver = Object.new
    agent = @agent
    recovery = @recovery
    receiver.define_singleton_method(:deliver_on_event_loop) do |_command|
      received << agent.retry_terminal_submission(recovery: recovery)
    rescue => error
      received << error
    end
    expect(@registry.post(Struct.new(:coordinator).new(receiver))).to be(true)
    expect(take(received)).to be_a(Phronomy::EventLoopReentrancyError)
    expect(@counts).to eq(provider: 2, tool: 1)
    expect_released(submit_again)
  end
end
