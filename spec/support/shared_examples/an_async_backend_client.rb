# frozen_string_literal: true

RSpec.shared_examples "an asynchronous backend client" do
  let(:timer) { Phronomy::Testing::FakeClock.new }
  let(:pool) do
    Phronomy::Concurrency::OffloadPool.new(
      pool_size: 1, queue_size: 1, timer_queue_provider: -> { timer }
    )
  end
  let(:client) { build_client(pool: pool) }

  after { pool.shutdown(drain_timeout: 2) }

  it "constructs and uses an injected pool without starting the default Runtime" do
    expect(Phronomy::Runtime.default_if_initialized_for_test).to be_nil
    instance = client
    expect(Phronomy::Runtime.default_if_initialized_for_test).to be_nil
    expect(invoke_async(instance).wait_result(timeout: 2)).to eq([])
    expect(Phronomy::Runtime.default_if_initialized_for_test).to be_nil
  end

  it "executes once on a worker and returns the exact submitted task" do
    worker = nil
    allow(sync_backend).to receive(sync_operation) do
      worker = Thread.current
      []
    end
    submitted = nil
    expect(pool).to receive(:submit).once.and_wrap_original do |method, **options, &work|
      expect(options).to eq(timeout: nil, cancellation_token: nil, on_full: :raise)
      submitted = method.call(**options, &work)
    end
    task = invoke_async(client)
    expect(task).to equal(submitted)
    expect(task.wait_result(timeout: 2)).to eq([])
    expect(worker).not_to equal(Thread.current)
    expect(sync_backend).to have_received(sync_operation).once
  end

  it "resolves a new default pool after Runtime reset" do
    instance = build_client
    expect(Phronomy::Runtime.default_if_initialized_for_test).to be_nil
    expect(invoke_async(instance).wait_result(timeout: 2)).to eq([])
    previous = Phronomy::Runtime.instance
    Phronomy.reset_runtime!
    expect(invoke_async(instance).wait_result(timeout: 2)).to eq([])
    expect(Phronomy::Runtime.instance).not_to equal(previous)
  end

  it "retains an injected pool across default Runtime resets" do
    instance = client
    Phronomy::Runtime.instance
    Phronomy.reset_runtime!
    expect(invoke_async(instance).wait_result(timeout: 2)).to eq([])
    expect(Phronomy::Runtime.default_if_initialized_for_test).to be_nil
  end

  it "preserves the original operation exception" do
    error = RuntimeError.new("backend failed")
    allow(sync_backend).to receive(sync_operation).and_raise(error)
    task = invoke_async(client)
    expect { task.wait_result(timeout: 2) }.to raise_error { |actual| expect(actual).to equal(error) }
  end

  it "raises immediately on full-queue admission without invoking the backend" do
    started = Queue.new
    release = Queue.new
    pool.submit {
      started << true
      release.pop
    }
    started.pop(timeout: 2)
    pool.submit(on_full: :raise) { :queued }
    expect(sync_backend).not_to receive(sync_operation)
    expect { invoke_async(client) }.to raise_error(Phronomy::BackpressureError)
  ensure
    release&.push(true)
  end

  it "raises immediately if the injected pool was shut down" do
    pool.shutdown(drain_timeout: 2)
    expect(sync_backend).not_to receive(sync_operation)
    expect { invoke_async(client) }.to raise_error(Phronomy::PoolShutdownError)
  end

  it "does not run an operation that was cancelled before submission" do
    token = Phronomy::Concurrency::CancellationToken.new
    token.cancel!
    expect(sync_backend).not_to receive(sync_operation)
    task = invoke_async(client, token: token)
    expect { task.wait_result(timeout: 2) }.to raise_error(Phronomy::CancellationError)
    expect(task.status).to eq(:cancelled)
  end

  it "includes queue wait in the timeout and skips expired queued work" do
    started = Queue.new
    release = Queue.new
    pool.submit {
      started << true
      release.pop
    }
    started.pop(timeout: 2)
    expect(sync_backend).not_to receive(sync_operation)
    task = invoke_async(client, timeout: 5)
    timer.advance(5)
    expect { task.wait_result(timeout: 2) }.to raise_error(Phronomy::TimeoutError)
    release << true
    pool.shutdown(drain_timeout: 2)
    expect(pool.abandoned_count).to eq(0)
  ensure
    release&.push(true)
  end

  [:timeout, :cancellation].each do |reason|
    it "settles running #{reason} once without interrupting the synchronous backend" do
      started = Queue.new
      release = Queue.new
      finished = Queue.new
      allow(sync_backend).to receive(sync_operation) do
        started << true
        release.pop
        finished << true
        []
      end
      token = Phronomy::Concurrency::CancellationToken.new
      task = invoke_async(client, token: token, timeout: (reason == :timeout) ? 5 : nil)
      events = []
      task.on_complete { |value, error| events << [value, error] }
      started.pop(timeout: 2)
      (reason == :timeout) ? timer.advance(5) : token.cancel!
      error_type = (reason == :timeout) ? Phronomy::TimeoutError : Phronomy::CancellationError
      expect { task.wait_result(timeout: 2) }.to raise_error(error_type)
      expect(finished).to be_empty
      release << true
      pool.shutdown(drain_timeout: 2)
      expect(finished.pop(timeout: 2)).to be(true)
      expect(events.size).to eq(1)
      expect(events.first.last).to be_a(error_type)
    ensure
      release&.push(true)
    end
  end
end
