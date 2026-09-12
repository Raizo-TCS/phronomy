# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe "Application Task and synchronous-work APIs" do
  it "creates settled base Tasks without initializing Runtime or copying values" do
    expect(Phronomy::Runtime).not_to receive(:instance)
    value = {output: "answer"}
    task = Phronomy::Task.completed(value, name: "cached")
    seen = []
    task.on_complete { |result, error| seen << [result, error] }

    expect(task).to be_instance_of(Phronomy::Task)
    expect(task.name).to eq("cached")
    expect(task.wait_result).to equal(value)
    expect(seen).to eq([[value, nil]])
    expect(Phronomy::Task.completed.wait_result).to be_nil
  end

  it "preserves the original failure for late callbacks and wait_result" do
    error = RuntimeError.new("already failed")
    task = Phronomy::Task.failed(error, name: "cached-error")
    seen = nil
    task.on_complete { |_value, failure| seen = failure }

    expect(task.status).to eq(:failed)
    expect(seen).to equal(error)
    expect { task.wait_result }.to raise_error { |failure| expect(failure).to equal(error) }
    expect { Phronomy::Task.failed(nil) }.to raise_error(ArgumentError)
    expect { Phronomy::Task.failed("error") }.to raise_error(ArgumentError)
  end

  it "does not create an unsettled physical handle when factories are inherited" do
    klass = Phronomy::Concurrency::PhysicalCompletionTask
    expect(klass.completed(1)).to be_instance_of(Phronomy::Task)
    expect(klass.failed(RuntimeError.new("failed"))).to be_instance_of(Phronomy::Task)
  end

  it "keeps map transformation and failure semantics for settled Tasks" do
    expect(Phronomy::Task.completed(21).map { |value| value * 2 }.wait_result).to eq(42)
    transformed = Phronomy::Task.completed(1).map { raise "invalid result" }
    expect { transformed.wait_result }.to raise_error(RuntimeError, "invalid result")
    original = RuntimeError.new("source failed")
    mapped = Phronomy::Task.failed(original).map { raise "must not transform" }
    expect { mapped.wait_result }.to raise_error { |error| expect(error).to equal(original) }
  end

  it "runs Blocking work on an existing worker and retains its physical Task" do
    caller = Thread.current
    task = Phronomy::Blocking.call_async { Thread.current }
    expect(task).to be_a(Phronomy::Concurrency::PhysicalCompletionTask)
    expect(task.wait_result(timeout: 2)).not_to be(caller)
  end

  it "returns a failed Task when admission fails instead of waiting for capacity" do
    Phronomy.configure do |configuration|
      configuration.offload_pool_size = 1
      configuration.offload_queue_size = 1
    end
    started = Queue.new
    release = Queue.new
    first = Phronomy::Blocking.call_async {
      started << true
      release.pop
    }
    Timeout.timeout(2) { started.pop }
    queued = Phronomy::Blocking.call_async { :queued }
    rejected = Timeout.timeout(2) { Phronomy::Blocking.call_async { :never } }

    expect(rejected).to be_instance_of(Phronomy::Task)
    expect { rejected.wait_result }.to raise_error(Phronomy::BackpressureError)
    release << true
    expect(first.wait_result(timeout: 2)).to be(true)
    expect(queued.wait_result(timeout: 2)).to eq(:queued)
  ensure
    release << true if release
  end

  it "reports Runtime shutdown through a failed Task" do
    runtime = Phronomy::Runtime.instance
    runtime.shutdown(timeout: 2)
    task = Phronomy::Blocking.call_async { :never }
    expect { task.wait_result }.to raise_error(Phronomy::RuntimeShutdownError)
  end

  it "preserves cancellation without executing the block" do
    token = Phronomy::Concurrency::CancellationToken.new
    token.cancel!
    task = Phronomy::Blocking.call_async(cancellation_token: token) { raise "must not execute" }
    expect(task.status).to eq(:cancelled)
    expect { task.wait_result }.to raise_error(Phronomy::CancellationError)
  end

  it "preserves physical completion after an operation timeout" do
    started = Queue.new
    release = Queue.new
    physically_done = Queue.new
    task = Phronomy::Blocking.call_async(timeout: 0.1) do
      started << true
      release.pop
      :late
    end
    task.on_physical_complete { physically_done << true }
    Timeout.timeout(2) { started.pop }
    expect { task.wait_result(timeout: 2) }.to raise_error(Phronomy::TimeoutError)
    expect(physically_done).to be_empty
    release << true
    expect(Timeout.timeout(2) { physically_done.pop }).to be(true)
  ensure
    release << true if release
  end

  it "rejects a missing work block at the call site" do
    expect { Phronomy::Blocking.call_async }.to raise_error(ArgumentError, /requires a block/)
  end

  it "rejects waiting admission on EventLoop before setting up an operation" do
    pool = Phronomy::Runtime.instance.offload
    allow(Phronomy::Runtime).to receive(:in_event_loop_context?).and_return(true)
    token = Phronomy::Concurrency::CancellationToken.new
    expect(token).not_to receive(:on_cancel)
    [:wait, :timeout].each do |policy|
      expect { pool.submit(on_full: policy, cancellation_token: token) { :never } }
        .to raise_error(Phronomy::EventLoopReentrancyError)
    end
  end
end
