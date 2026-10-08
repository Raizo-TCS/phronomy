# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::AsyncOperation do
  it "adapts duplicate callback notifications only once, without requiring a TaskResult" do
    notifications = []
    source = Object.new
    source.define_singleton_method(:on_complete) { |&callback| notifications << callback }
    values = []
    result = described_class.map(source, name: "callback") { |value|
      values << value
      value * 2
    }
    notifications.first.call(3, nil)
    notifications.first.call(9, nil)
    expect(result.wait_result).to eq(6)
    expect(values).to eq([3])
  end

  it "applies the same error policy to synchronous startup and asynchronous failure" do
    error = RuntimeError.new("unavailable")
    errors = []
    policy = ->(failure) {
      errors << failure
      "fallback"
    }
    first = described_class.call(name: "startup", on_error: policy) { raise error }
    source = Phronomy::TaskResult.deferred
    second = described_class.call(name: "later", on_error: policy) { source }
    source.fail(error)
    expect([first.wait_result, second.wait_result]).to eq(["fallback", "fallback"])
    expect(errors).to eq([error, error])
  end

  it "does not recursively recover an error raised by the error policy" do
    source_error = RuntimeError.new("original")
    policy_error = Phronomy::ToolError.new("domain failure")
    errors = []
    result = described_class.call(name: "policy", on_error: ->(error) {
      errors << error
      raise policy_error
    }) do
      raise source_error
    end
    expect { result.wait_result }.to raise_error { |error| expect(error).to equal(policy_error) }
    expect(errors).to eq([source_error])
  end

  it "recovers a transformation failure once" do
    error = RuntimeError.new("transform")
    errors = []
    result = described_class.map(Phronomy::TaskResult.completed(1), name: "transform",
      on_error: ->(failure) {
        errors << failure
        "fallback"
      }) { raise error }
    expect(result.wait_result).to eq("fallback")
    expect(errors).to eq([error])
  end

  it "keeps recovery physically active until both the source and policy finish" do
    source = Phronomy::Concurrency::PhysicalCompletionTask.deferred
    entered = Queue.new
    release = Queue.new
    result = described_class.map(source, name: "physical", on_error: ->(_error) {
      entered << true
      release.pop
      "fallback"
    }) { |value| value }
    thread = Thread.new { source.fail(RuntimeError.new("failure")) }
    Timeout.timeout(2) { entered.pop }
    source.mark_physical_complete!
    expect(result.physical_complete?).to be(false)
    release << true
    expect(result.wait_result(timeout: 2)).to eq("fallback")
    expect(result.physical_complete?).to be(true)
  ensure
    release << true if release
    thread&.join(2)
  end

  it "preserves cancellation identity when no recovery policy is supplied" do
    source = Phronomy::TaskResult.deferred
    error = Phronomy::CancellationError.new("cancelled")
    result = described_class.map(source, name: "cancel") { raise "must not transform" }
    source.cancel!(error)
    expect(result.status).to eq(:cancelled)
    expect { result.wait_result }.to raise_error { |failure| expect(failure).to equal(error) }
  end
end

RSpec.describe "Execution control ownership" do
  it "bounds admitted work and does not start queued jobs after cancellation" do
    token = Phronomy::Concurrency::CancellationToken.new
    started = []
    jobs = []
    result = Phronomy::Execution.run_async([1, 2, 3], max_concurrency: 1, cancellation_token: token) do |input, _execution|
      started << input
      jobs << Phronomy::TaskResult.deferred
      jobs.last
    end
    expect(started).to eq([1])
    jobs.first.complete(1)
    expect(started).to eq([1, 2])
    token.cancel!
    jobs.last.complete(2)
    expect(started).to eq([1, 2])
    expect { result.wait_result }.to raise_error(Phronomy::ExecutionCancellationError)
  end

  [0, -1, false, 1.5, "2"].each do |limit|
    it "rejects invalid max_concurrency #{limit.inspect} before starting any job" do
      expect { Phronomy::Execution.run_async([1], max_concurrency: limit) { raise "started" } }
        .to raise_error(ArgumentError, /positive Integer/)
    end
  end

  it "preserves an explicit child context and disconnects controls when the child settles" do
    child_context = Phronomy::InvocationContext.new(user_id: "child")
    child_token = Phronomy::Concurrency::CancellationToken.new
    child = Phronomy::TaskResult.deferred
    observed_token = nil
    parent = Phronomy::Execution.run_async([1]) do |_input, execution|
      execution.start_child(invocation_context: child_context, cancellation_token: child_token) do |context, token|
        expect(context).to equal(child_context)
        observed_token = token
        child
      end
    end
    child.complete("done")
    expect(parent.wait_result.first.value).to eq("done")
    child_token.cancel!
    expect(observed_token.cancelled?).to be(false)
  end

  it "disconnects child controls when child startup raises" do
    child_token = Phronomy::Concurrency::CancellationToken.new
    observed_token = nil
    parent = Phronomy::Execution.run_async([1]) do |_input, execution|
      execution.start_child(cancellation_token: child_token) do |_context, token|
        observed_token = token
        raise "startup failed"
      end
    end
    expect(parent.wait_result.first.error.message).to eq("startup failed")
    child_token.cancel!
    expect(observed_token.cancelled?).to be(false)
  end
end
