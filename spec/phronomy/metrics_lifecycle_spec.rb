# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe Phronomy::Metrics, "resource lifetime" do
  def await_signal(queue)
    queue.pop(timeout: 2) || raise("metrics test barrier timed out")
  end

  def default_pool(runtime)
    runtime.instance_variable_get(:@pool_registry).instance_variable_get(:@default)
  end

  def expect_no_timer(runtime)
    expect(runtime.instance_variable_get(:@timer_service).instance_variable_get(:@timer)).to be_nil
  end

  it "keeps Metrics and Diagnostics passive in a fresh process" do
    script = <<~RUBY
      require "phronomy"
      require "stringio"
      before = Thread.list
      snapshots = [Phronomy::Metrics.snapshot, Phronomy::Diagnostics.snapshot]
      Phronomy::Diagnostics.dump(out: StringIO.new)
      abort "created Runtime" if Phronomy::Runtime.default_if_initialized_for_test
      abort "created threads" unless Thread.list == before
      abort "unexpected values" unless snapshots.all? { |s| s.size == 10 && s.values.all?(&:zero?) }
    RUBY
    _out, error, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script)
    expect(status.success?).to be(true), error
  end

  it "leaves an initialized Runtime's missing resources uninitialized" do
    runtime = Phronomy::Runtime.instance
    before = Thread.list
    3.times { expect(described_class.snapshot.values).to all(eq(0)) }
    expect(Phronomy::Runtime.default_if_initialized_for_test).to equal(runtime)
    expect(default_pool(runtime)).to be_nil
    expect(runtime.__event_loop_if_initialized).to be_nil
    expect_no_timer(runtime)
    expect(Thread.list).to eq(before)
    expect(runtime.state).to eq(:running)
  end

  it "does not create a default pool or aggregate named pools" do
    runtime = Phronomy::Runtime.instance
    named = runtime.pool(:application, size: 2, queue_size: 1)
    expect(described_class.snapshot.values).to all(eq(0))
    expect(default_pool(runtime)).to be_nil
    expect(runtime.__event_loop_if_initialized).to be_nil
    expect(runtime.pool(:application)).to equal(named)
  end

  it "reads real active, queued and abandoned work without creating an EventLoop" do
    runtime = Phronomy::Runtime.instance
    pool = runtime.offload(pool_size: 1, queue_size: 1)
    entered = Queue.new
    release = Queue.new
    token = Phronomy::Concurrency::CancellationToken.new
    active = pool.submit(cancellation_token: token) {
      entered << true
      await_signal(release)
      :finished
    }
    await_signal(entered)
    queued = pool.submit { :queued }
    token.cancel!
    expect(active.status).to eq(:cancelled)
    snap = described_class.snapshot
    expect(snap).to include(offload_pool_size: 1, offload_pool_active: 1,
      offload_pool_queue_length: 1, offload_pool_abandoned_active: 1, offload_pool_abandoned_total: 1)
    expect(snap.select { |key, _| key.to_s.start_with?("event_loop_") }.values).to all(eq(0))
    expect(runtime.__event_loop_if_initialized).to be_nil
    expect_no_timer(runtime)
  ensure
    release << true
    queued&.wait_result(timeout: 2)
    pool&.shutdown(drain_timeout: 1)
  end

  it "reads EventLoop backlog and lag without creating a pool" do
    runtime = Phronomy::Runtime.instance
    event_loop = runtime.event_loop
    entered = Queue.new
    release = Queue.new
    completion = Phronomy::TaskResult.deferred(name: "metrics-lifecycle")
    session = double("session", id: "metrics-lifecycle", handle: nil)
    allow(session).to receive(:start) do
      entered << true
      await_signal(release)
      event_loop.post(Phronomy::Event.new(type: :finished,
        target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
        payload: {fsm_session_id: session.id, result: :finished}))
    end
    event_loop.register(session, completion: completion)
    await_signal(entered)
    2.times { event_loop.post(Phronomy::Event.new(type: :probe, target_id: session.id, payload: nil)) }
    snap = described_class.snapshot
    expect(snap[:event_loop_queue_depth]).to eq(2)
    expect(snap[:event_loop_queue_max_depth]).to eq(event_loop.max_queue_depth)
    expect(snap[:event_loop_lag_last_ms]).to eq((event_loop.last_lag_seconds * 1000).round(3))
    expect(snap[:event_loop_lag_max_ms]).to eq((event_loop.max_lag_seconds * 1000).round(3))
    expect(snap[:event_loop_lag_average_ms]).to eq((event_loop.average_lag_seconds * 1000).round(3))
    expect(snap.select { |key, _| key.to_s.start_with?("offload_pool_") }.values).to all(eq(0))
    expect(default_pool(runtime)).to be_nil
  ensure
    release << true
    completion&.wait_result(timeout: 2)
  end

  it "retains existing counters and capacity after completed shutdown" do
    runtime = Phronomy::Runtime.instance
    pool = runtime.offload(pool_size: 2, queue_size: 1)
    event_loop = runtime.event_loop
    expect(pool.submit { :done }.wait_result(timeout: 1)).to eq(:done)
    expect(runtime.shutdown(timeout: 1).cleanup_complete?).to be(true)
    snap = described_class.snapshot
    expect(snap).to include(offload_pool_size: 2, offload_pool_active: 0, offload_pool_queue_length: 0)
    expect(snap[:event_loop_queue_max_depth]).to eq(event_loop.max_queue_depth)
    expect(Phronomy::Diagnostics.snapshot).to eq(snap)
    expect { Phronomy::Diagnostics.dump(out: StringIO.new) }.not_to raise_error
    expect(default_pool(runtime)).to equal(pool)
    expect(runtime.__event_loop_if_initialized).to equal(event_loop)
    expect(runtime.state).to eq(:terminated)
  end

  it "does not initialize resources of an already stopped empty Runtime" do
    runtime = Phronomy::Runtime.instance
    expect(runtime.shutdown.cleanup_complete?).to be(true)
    expect(described_class.snapshot.values).to all(eq(0))
    expect(default_pool(runtime)).to be_nil
    expect(runtime.__event_loop_if_initialized).to be_nil
    expect_no_timer(runtime)
    expect(runtime.state).to eq(:terminated)
  end

  it "keeps live worker metrics readable after incomplete shutdown" do
    runtime = Phronomy::Runtime.instance
    pool = runtime.offload(pool_size: 1, queue_size: 1)
    entered = Queue.new
    release = Queue.new
    task = pool.submit {
      entered << true
      await_signal(release)
      :finished
    }
    await_signal(entered)
    result = runtime.shutdown(timeout: 0, cancel_grace: 0)
    expect(result.cleanup_complete?).to be(false)
    expect(described_class.snapshot).to include(offload_pool_size: 1, offload_pool_active: 1)
    expect(runtime.state).to eq(:failed)
    expect(runtime.shutdown).to equal(result)
    expect(Phronomy::Runtime.default_if_initialized_for_test).to equal(runtime)
    expect(runtime.__event_loop_if_initialized).to be_nil
  ensure
    release << true
    task&.wait_result(timeout: 2)
    pool&.shutdown(drain_timeout: 1)
  end

  it "does not create resources while Runtime drains" do
    runtime = Phronomy::Runtime.instance
    entered = Queue.new
    release = Queue.new
    participant = double("participant", begin_draining: nil)
    allow(participant).to receive(:wait_until_idle) do |_deadline|
      entered << true
      await_signal(release)
      true
    end
    runtime.__register_shutdown_participant(key: :metrics, participant: participant)
    stopping = Thread.new { runtime.shutdown(timeout: 1) }
    await_signal(entered)
    expect(runtime.state).to eq(:draining)
    expect(described_class.snapshot.values).to all(eq(0))
    expect(default_pool(runtime)).to be_nil
    expect(runtime.__event_loop_if_initialized).to be_nil
    release << true
    expect(stopping.join(2)).not_to be_nil
    expect(stopping.value.cleanup_complete?).to be(true)
  ensure
    release << true
    stopping&.join(2)
  end

  it "reads retained resources while Runtime stops without reopening admission" do
    runtime = Phronomy::Runtime.instance
    pool = runtime.offload(pool_size: 1, queue_size: 1)
    entered = Queue.new
    release = Queue.new
    allow(pool).to receive(:shutdown).and_wrap_original do |original, **options|
      entered << true
      await_signal(release)
      original.call(**options)
    end
    stopping = Thread.new { runtime.shutdown(timeout: 1) }
    await_signal(entered)
    expect(runtime.state).to eq(:stopping)
    expect(described_class.snapshot[:offload_pool_size]).to eq(1)
    expect { pool.submit { :too_late } }.to raise_error(Phronomy::PoolShutdownError)
    expect(runtime.__event_loop_if_initialized).to be_nil
    release << true
    expect(stopping.join(2)).not_to be_nil
    expect(stopping.value.cleanup_complete?).to be(true)
  ensure
    release << true
    stopping&.join(2)
    allow(pool).to receive(:shutdown).and_call_original if pool
    pool&.shutdown(drain_timeout: 1)
  end

  it "follows default Runtime replacement without creating or retaining a Runtime" do
    first = Phronomy::Runtime.instance
    first.offload(pool_size: 2, queue_size: 1)
    expect(described_class.snapshot[:offload_pool_size]).to eq(2)
    Phronomy.reset_runtime!
    expect(described_class.snapshot.values).to all(eq(0))
    expect(Phronomy::Runtime.default_if_initialized_for_test).to be_nil
    second = Phronomy::Runtime.instance
    second.offload(pool_size: 3, queue_size: 1)
    expect(described_class.snapshot[:offload_pool_size]).to eq(3)
    expect(Phronomy::Runtime.default_if_initialized_for_test).to equal(second)
    expect(second).not_to equal(first)
  end
end
