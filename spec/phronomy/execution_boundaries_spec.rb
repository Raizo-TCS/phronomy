# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "Execution responsibility boundaries" do
  it "uses values and result composition without loading Engine" do
    source = <<~RUBY
      require "phronomy"
      deadline = Phronomy::Concurrency::Deadline.in(30)
      context = Phronomy::InvocationContext.new(deadline: deadline)
      context.merge(user_id: "preview")
      result = Phronomy::TaskResult.completed(2).map { |v| v * 3 }
        .flat_map { |v| Phronomy::TaskResult.completed(v + 1) }
      abort "result changed" unless result.wait_result == 7
      outcomes = Phronomy::TaskResult.all_settled([result]).wait_result
      abort "collector changed" unless outcomes.first.value == 7
      loaded = $LOADED_FEATURES.grep(%r{/phronomy/engine/})
      abort "mechanism loaded: \#{loaded.inspect}" unless loaded.empty?
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby,
      "-I", File.expand_path("../../lib", __dir__), "-e", source)
    expect(status.success?).to be(true), [stdout, stderr].join("\n")
  end

  it "binds a neutral scope to context and observed results, retaining the same scope" do
    context = observed = scope = nil
    source = Phronomy::TaskResult.deferred
    aggregate = Phronomy::Execution.run_async([1]) do |_, execution|
      context = execution.invocation_context
      observed = execution.observe(source)
      scope = context.__execution_scope
      observed
    end
    expect(scope).to be_a(Phronomy::ExecutionScopeState)
    expect(observed.__execution_scope).to be(scope)
    expect(scope.instance_variables.map { |name| scope.instance_variable_get(name) })
      .not_to include(an_instance_of(Phronomy::Execution))
    source.complete(:done)
    expect(aggregate.wait_result.first.value).to eq(:done)
    expect(scope.__open?).to be(false)
  end

  it "restores nested blocking policy on exceptions without affecting another thread" do
    expect(Phronomy::WaitPolicy.blocking_forbidden?).to be(false)
    Phronomy::WaitPolicy.without_blocking do
      expect(Phronomy::WaitPolicy.blocking_forbidden?).to be(true)
      expect(Thread.new { Phronomy::WaitPolicy.blocking_forbidden? }.value).to be(false)
      expect do
        Phronomy::WaitPolicy.without_blocking { raise "probe" }
      end.to raise_error("probe")
      expect(Phronomy::WaitPolicy.blocking_forbidden?).to be(true)
      expect { Phronomy::TaskResult.deferred.wait_result }
        .to raise_error(Phronomy::EventLoopReentrancyError)
    end
    expect(Phronomy::WaitPolicy.blocking_forbidden?).to be(false)
  end
end

RSpec.describe Phronomy::InvocationControls do
  it "returns no control when none is specified" do
    expect(described_class.effective_timeout_token(Phronomy::InvocationContext.new)).to be_nil
  end

  it "preserves an explicit token even when a competing deadline is expired" do
    token = Phronomy::Concurrency::CancellationToken.new
    context = Phronomy::InvocationContext.new(cancellation_token: token,
      deadline: Phronomy::Concurrency::Deadline.in(-1))
    expect(described_class.effective_timeout_token(context)).to be(token)
    expect(token.cancelled?).to be(false)
  end

  it "cancels immediately for an expired deadline without acquiring Runtime" do
    expect(Phronomy::Runtime).not_to receive(:instance)
    context = Phronomy::InvocationContext.new(deadline: Phronomy::Concurrency::Deadline.in(-1))
    expect(described_class.effective_timeout_token(context).cancelled?).to be(true)
  end

  it "cancels at the deadline and removes the registered timer" do
    runtime = Phronomy::Runtime.instance
    context = Phronomy::InvocationContext.new(deadline: Phronomy::Concurrency::Deadline.in(0.05))
    token = described_class.effective_timeout_token(context)
    cancelled = Queue.new
    token.on_cancel { cancelled << true }
    expect(Timeout.timeout(2) { cancelled.pop }).to be(true)
    expect(token.cancelled?).to be(true)
    expect(runtime.timer_queue.pending_count).to eq(0)
  end

  it "removes a future timer when cancelled explicitly" do
    runtime = Phronomy::Runtime.instance
    context = Phronomy::InvocationContext.new(deadline: Phronomy::Concurrency::Deadline.in(30))
    token = described_class.effective_timeout_token(context)
    expect(runtime.timer_queue.pending_count).to eq(1)
    token.cancel!
    expect(runtime.timer_queue.pending_count).to eq(0)
  end
end
