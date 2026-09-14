# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe Phronomy::Execution do
  let(:tr) { Phronomy::TaskResult }
  let(:token_class) { Phronomy::Concurrency::CancellationToken }

  def failure_of(result)
    result.wait_result(timeout: 2)
    raise "expected a failure"
  rescue Phronomy::TimeoutError, Phronomy::CancellationError => error
    error
  end

  it "uses one input-order start loop for zero, one and many jobs without starting worker threads" do
    expect(Phronomy::Runtime).not_to receive(:instance)
    [[], [1], [1, 2, 3]].each do |inputs|
      seen = []
      outcomes = described_class.run(inputs) do |input, execution|
        seen << [input, Thread.current]
        expect(execution.invocation_context).to be_a(Phronomy::InvocationContext)
        tr.completed(input * 2)
      end
      expect(seen.map(&:first)).to eq(inputs)
      expect(seen.map(&:last)).to all(eq(Thread.current))
      expect(outcomes.map(&:value)).to eq(inputs.map { |i| i * 2 })
    end
  end

  it "starts all jobs before waiting and snapshots the input positions" do
    inputs = [:a, :b, :c]
    sources = inputs.to_h { |key| [key, tr.deferred] }
    started = []
    combined = described_class.run_async(inputs) do |input, _|
      started << input
      inputs.clear
      sources.fetch(input)
    end
    expect(started).to eq([:a, :b, :c])
    sources[:c].complete(3)
    sources[:a].complete(1)
    expect(combined).not_to be_done
    sources[:b].complete(2)
    expect(combined.wait_result.map(&:value)).to eq([1, 2, 3])
  end

  it "keeps a start exception and a wrong return as job failures and waits for other jobs" do
    pending = tr.deferred
    original = RuntimeError.new("construction failed")
    combined = described_class.run_async([0, 1, 2]) do |i, _|
      case i
      when 0 then raise original
      when 1 then :not_a_result
      else pending
      end
    end
    expect(combined).not_to be_done
    pending.complete(:ok)
    outcomes = combined.wait_result
    expect(outcomes.map(&:status)).to eq([:failed, :failed, :completed])
    expect(outcomes[0].error).to equal(original)
    expect(outcomes[1].error).to be_a(TypeError)
    expect(outcomes[1].error.message).to include("inputs[1]", "TaskResult")
  end

  it "rejects invalid arguments before jobs or cancellation subscriptions" do
    token = token_class.new
    expect(token).not_to receive(:on_cancel)
    [nil, {}, :wrong].each do |inputs|
      expect { described_class.run_async(inputs, cancellation_token: token) {} }.to raise_error(TypeError)
    end
    expect { described_class.run_async([], cancellation_token: token) }.to raise_error(ArgumentError)
    ["1", false].each do |timeout|
      expect { described_class.run_async([], timeout: timeout, cancellation_token: token) {} }.to raise_error(TypeError)
    end
    [Float::NAN, Float::INFINITY, -Float::INFINITY, Complex(1, 0)].each do |timeout|
      expect { described_class.run_async([], timeout: timeout, cancellation_token: token) {} }.to raise_error(ArgumentError)
    end
    [false, {}, Object.new].each do |bad|
      expect { described_class.run_async([], cancellation_token: bad) {} }.to raise_error(TypeError)
      expect { described_class.run_async([], invocation_context: bad, cancellation_token: token) {} }.to raise_error(TypeError)
    end
  end

  it "prevents all starts for nonpositive deadlines and already cancelled tokens, including empty input" do
    [[], [1, 2]].each do |inputs|
      [0, -1].each do |timeout|
        result = described_class.run_async(inputs, timeout: timeout) { raise "must not start" }
        expect(failure_of(result)).to be_a(Phronomy::ExecutionTimeoutError)
        expect(result.status).to eq(:failed)
      end
      token = token_class.new.cancel!
      result = described_class.run_async(inputs, cancellation_token: token) { raise "must not start" }
      expect(failure_of(result)).to be_a(Phronomy::ExecutionCancellationError)
      expect(result.status).to eq(:cancelled)
    end
  end

  it "retains transformed values, original errors and unfinished final results at timeout" do
    pending = tr.deferred
    original = RuntimeError.new("individual failure")
    combined = described_class.run_async([0, 1, 2, 3], timeout: 0.02) do |i, _|
      case i
      when 0 then tr.completed(21).map { |v| v * 2 }
      when 1 then tr.failed(original)
      else tr.completed(:started).flat_map { pending }
      end
    end
    error = failure_of(combined)
    expect(error).to be_a(Phronomy::ExecutionTimeoutError)
    expect(error.outcomes.map(&:status)).to eq([:completed, :failed, :unfinished, :unfinished])
    expect(error.outcomes[0].value).to eq(42)
    expect(error.outcomes[1].error).to equal(original)
    expect(error.outcomes).to be_frozen
    pending.complete(:late)
    expect(error.outcomes.map(&:status)).to eq([:completed, :failed, :unfinished, :unfinished])
    expect(combined.status).to eq(:failed)
  end

  it "fixes the cancellation snapshot before cancelling scoped observations and leaves the source untouched" do
    source = tr.deferred
    token = token_class.new
    continuation = nil
    notifications = []
    combined = described_class.run_async([source], cancellation_token: token) do |input, execution|
      continuation = execution.observe(input).map { raise "must not execute" }
      continuation.on_complete { |_, e| notifications << e }
      continuation
    end
    token.cancel!
    error = failure_of(combined)
    expect(error.outcomes.first.status).to eq(:unfinished)
    expect(continuation.status).to eq(:cancelled)
    expect(notifications.length).to eq(1)
    expect(source).not_to be_done
    source.complete(:shared_value)
    expect(source.wait_result).to eq(:shared_value)
    expect(error.outcomes.first.status).to eq(:unfinished)
  end

  it "does not inherit the inner scope in outer transformations registered before or after completion" do
    source = tr.deferred
    scope = nil
    combined = described_class.run_async([1], timeout: 30) do |_, execution|
      scope = execution
      execution.observe(source).map { |v| v * 2 }
    end
    before = combined.map { |outcomes| outcomes.first.value + 1 }
    source.complete(20)
    expect(before.wait_result).to eq(41)
    after = combined.flat_map { |outcomes| tr.completed(outcomes.first.value + 2) }
    expect(after.wait_result).to eq(42)
    suppressed = scope.observe(tr.completed(1)).map { raise "closed scope" }
    expect(suppressed.status).to eq(:cancelled)
    expect(Phronomy::Runtime.instance.timer_queue.pending_count).to eq(0)
  end

  it "preserves parent context metadata and combines parent and explicit cancellation one way" do
    policy = Object.new
    parent_token = token_class.new
    parent = Phronomy::InvocationContext.new(user_id: "u1", approval_policy: policy,
      token_budget: 10, task_id: "trace", cancellation_token: parent_token)
    local_token = token_class.new
    context = nil
    combined = described_class.run_async([1], invocation_context: parent,
      cancellation_token: local_token) do |_, execution|
      context = execution.invocation_context
      tr.deferred
    end
    expect(context).not_to equal(parent)
    expect(context.approval_policy).to equal(policy)
    expect(context.user_id).to eq("u1")
    expect(context.task_id).to eq("trace")
    expect(context.token_budget).to eq(10)
    local_token.cancel!
    expect(combined.status).to eq(:cancelled)
    expect(parent_token).not_to be_cancelled
    expect(parent.cancellation_token).to equal(parent_token)

    sibling = described_class.run_async([1], invocation_context: parent) { tr.deferred }
    parent_token.cancel!
    expect(sibling.status).to eq(:cancelled)
  end

  it "distinguishes a context deadline, a token deadline and an Execution timeout" do
    context = Phronomy::InvocationContext.new(deadline: Phronomy::Concurrency::Deadline.in(0.02))
    inherited = described_class.run_async([1], invocation_context: context, timeout: 20) { tr.deferred }
    expect(failure_of(inherited)).to be_a(Phronomy::ExecutionCancellationError)
    token_result = described_class.run_async([1], cancellation_token: token_class.timeout_after(0.02)) { tr.deferred }
    expect(failure_of(token_result)).to be_a(Phronomy::ExecutionCancellationError)
    explicit = described_class.run_async([1], timeout: 0.02) { tr.deferred }
    expect(failure_of(explicit)).to be_a(Phronomy::ExecutionTimeoutError)
  end

  it "stops unstarted jobs when cancellation wins during an earlier start block" do
    token = token_class.new
    seen = []
    combined = described_class.run_async([0, 1, 2], cancellation_token: token) do |i, _|
      seen << i
      token.cancel!
      tr.completed(i)
    end
    expect(seen).to eq([0])
    expect(failure_of(combined).outcomes.map(&:status)).to eq([:unfinished, :unfinished, :unfinished])
  end

  it "does not join or cancel unreturned work at normal completion" do
    release = Queue.new
    started = Queue.new
    orphan = nil
    combined = described_class.run_async([1], timeout: 30) do |_, execution|
      orphan = Phronomy::Blocking.call_async(invocation_context: execution.invocation_context) do
        started << true
        release.pop
        :independent
      end
      Timeout.timeout(2) { started.pop }
      tr.completed(:returned)
    end
    expect(combined.wait_result.map(&:value)).to eq([:returned])
    expect(orphan).not_to be_done
    release << true
    expect(orphan.wait_result(timeout: 2)).to eq(:independent)
  ensure
    release << true if release
  end

  it "keeps cancellation local and physical tracking alive for explicitly scoped Blocking work" do
    token = token_class.new
    individual = token_class.new
    started = Queue.new
    release = Queue.new
    physical = Queue.new
    work = nil
    combined = described_class.run_async([1], cancellation_token: token) do |_, execution|
      work = Phronomy::Blocking.call_async(invocation_context: execution.invocation_context,
        cancellation_token: individual) do
        started << true
        release.pop
        :late
      end.map { raise "must not transform cancelled work" }
      work.on_physical_complete { physical << true }
      work
    end
    Timeout.timeout(2) { started.pop }
    token.cancel!
    expect(failure_of(combined).outcomes.first.status).to eq(:unfinished)
    expect(individual).not_to be_cancelled
    expect(work.status).to eq(:cancelled)
    expect(work.physical_complete?).to be false
    release << true
    Timeout.timeout(2) { physical.pop }
    expect(work.physical_complete?).to be true
  ensure
    release << true if release
  end

  it "records individual cancellation while the other jobs continue" do
    individual = token_class.new.cancel!
    shared = token_class.new
    pending = tr.deferred
    combined = described_class.run_async([0, 1], cancellation_token: shared) do |i, execution|
      if i.zero?
        Phronomy::Blocking.call_async(invocation_context: execution.invocation_context,
          cancellation_token: individual) { raise "must not run" }
      else
        pending
      end
    end
    expect(shared).not_to be_cancelled
    expect(combined).not_to be_done
    pending.complete(:ok)
    expect(combined.wait_result.map(&:status)).to eq([:cancelled, :completed])
  end

  it "serializes competing last completion and cancellation without inconsistent duplicate positions" do
    30.times do
      source = tr.deferred
      token = token_class.new
      combined = described_class.run_async([source, source], cancellation_token: token) { |input, _| input }
      threads = [Thread.new { source.complete(:ok) }, Thread.new { token.cancel! }]
      threads.each(&:join)
      if combined.status == :completed
        expect(combined.wait_result.map(&:status)).to eq([:completed, :completed])
      else
        expect(failure_of(combined).outcomes.map(&:status)).to eq([:unfinished, :unfinished])
      end
    end
  end

  it "reports an invalid Blocking context as an admission failure without starting work" do
    expect(Phronomy::Runtime).not_to receive(:instance)
    [false, {}].each do |context|
      result = Phronomy::Blocking.call_async(invocation_context: context) { raise "must not run" }
      expect(result.status).to eq(:failed)
      expect { result.wait_result }.to raise_error(TypeError, /InvocationContext/)
    end
  end

  it "does not take cancellation or physical ownership of an external flat_map result" do
    started = Queue.new
    release = Queue.new
    external_token = token_class.new
    external = Phronomy::Blocking.call_async(cancellation_token: external_token) do
      started << true
      release.pop
      21
    end
    original_continuation = external.map { |value| value * 2 }
    Timeout.timeout(2) { started.pop }
    whole_token = token_class.new
    scoped = nil
    combined = described_class.run_async([1], cancellation_token: whole_token) do |_, execution|
      scoped = execution.observe(tr.completed(:ready)).flat_map { external }
    end
    whole_token.cancel!
    expect(failure_of(combined).outcomes.first.status).to eq(:unfinished)
    expect(scoped.status).to eq(:cancelled)
    expect(scoped.physical_complete?).to be true
    expect(external_token).not_to be_cancelled
    expect(external).not_to be_done
    expect(external.physical_complete?).to be false
    release << true
    expect(original_continuation.wait_result(timeout: 2)).to eq(42)
  ensure
    release << true if release
  end

  it "tracks a running continuation through cancellation and refuses its late scoped operation" do
    source = tr.deferred
    whole_token = token_class.new
    entered = Queue.new
    release = Queue.new
    physical = Queue.new
    late_operation = nil
    scoped = nil
    combined = described_class.run_async([source], cancellation_token: whole_token) do |input, execution|
      scoped = execution.observe(input).flat_map do
        entered << true
        release.pop
        late_operation = Phronomy::Blocking.call_async(invocation_context: execution.invocation_context) do
          raise "closed scope must not start this operation"
        end
      end
      scoped.on_physical_complete { physical << true }
      scoped
    end
    completing_thread = Thread.new { source.complete(:ready) }
    Timeout.timeout(2) { entered.pop }
    whole_token.cancel!
    expect(failure_of(combined)).to be_a(Phronomy::ExecutionCancellationError)
    expect(scoped.status).to eq(:cancelled)
    expect(scoped.physical_complete?).to be false
    release << true
    Timeout.timeout(2) { physical.pop }
    completing_thread.join
    expect(late_operation.status).to eq(:cancelled)
    expect(scoped.physical_complete?).to be true
  ensure
    release << true if release
    completing_thread&.join(2)
  end

  it "stops scoped work that is still queued behind an unrelated running worker" do
    Phronomy.configure do |configuration|
      configuration.offload_pool_size = 1
      configuration.offload_queue_size = 4
    end
    started = Queue.new
    release = Queue.new
    ran = Queue.new
    blocker = Phronomy::Blocking.call_async do
      started << true
      release.pop
    end
    Timeout.timeout(2) { started.pop }
    combined = described_class.run_async([1, 2], timeout: 0.02) do |input, execution|
      Phronomy::Blocking.call_async(invocation_context: execution.invocation_context) { ran << input }
        .map { ran << :mapped }
    end
    expect(failure_of(combined).outcomes.map(&:status)).to eq([:unfinished, :unfinished])
    release << true
    blocker.wait_result(timeout: 2)
    # A barrier after the cancelled queue entries proves the worker consumed
    # those entries without running either application block.
    Phronomy::Blocking.call_async { :barrier }.wait_result(timeout: 2)
    expect(ran).to be_empty
  ensure
    release << true if release
  end

  it "rejects every synchronous entrance on the real EventLoop and permits async Blocking composition there" do
    delivered = tr.deferred
    Phronomy::Runtime.instance.timer_queue.schedule(seconds: 0) do
      [[], [1], [1, 2]].each do |inputs|
        expect { described_class.run(inputs) { tr.completed(1) } }
          .to raise_error(Phronomy::EventLoopReentrancyError)
      end
      source = described_class.run_async([21]) do |input, execution|
        Phronomy::Blocking.call_async(invocation_context: execution.invocation_context) { input }
          .map { |value| value * 2 }
      end
      source.on_complete { |value, error| error ? delivered.fail(error) : delivered.complete(value) }
    rescue StandardError, RSpec::Expectations::ExpectationNotMetError => error
      delivered.fail(error)
    end
    expect(delivered.wait_result(timeout: 2).map(&:value)).to eq([42])
  end
end
