# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Runtime resource lifecycle" do
  def await_signal(queue)
    queue.pop(timeout: 2) || raise("lifecycle test barrier timed out")
  end

  def wait_until_sleeping(thread)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until thread.status == "sleep"
      raise "thread did not reach its blocking boundary" if !thread.alive? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      Thread.pass
    end
  end

  it "owns one default pool when first lookups overlap during construction" do
    runtime = Phronomy::Runtime.new
    entered = Queue.new
    release = Queue.new
    threads = []
    pools = []
    allow(Phronomy::Concurrency::OffloadPool).to receive(:new).and_wrap_original do |original, **options|
      entered << true
      await_signal(release)
      original.call(**options)
    end
    threads << Thread.new { runtime.offload(pool_size: 1, queue_size: 1) }
    await_signal(entered)
    threads << Thread.new { runtime.offload(pool_size: 1, queue_size: 1) }
    wait_until_sleeping(threads.last)
    2.times { release << true }
    threads.each { |thread| expect(thread.join(2)).not_to be_nil }
    pools = threads.map(&:value)
    expect(pools.first).to equal(pools.last)
    expect(runtime.shutdown.cleanup_complete?).to be(true)
    expect(pools.flat_map { |pool| pool.instance_variable_get(:@workers) }.none?(&:alive?)).to be(true)
  ensure
    2.times { release << true }
    threads.each { |thread| thread.join(2) }
    pools |= threads.filter_map { |thread| thread.value unless thread.alive? }
    pools.each { |pool| pool.shutdown(drain_timeout: 1) }
    runtime&.shutdown
  end

  {default_pool: ->(runtime) { runtime.offload(pool_size: 1, queue_size: 1) },
   named_pool: ->(runtime) { runtime.pool(:late, size: 1, queue_size: 1) }}.each do |lookup, request|
    it "rejects #{lookup} creation that passed the Runtime check before shutdown" do
      runtime = Phronomy::Runtime.new
      registry = runtime.instance_variable_get(:@pool_registry)
      entered = Queue.new
      release = Queue.new
      allow(registry).to receive(lookup).and_wrap_original do |original, *args, **options|
        entered << true
        await_signal(release)
        original.call(*args, **options)
      end
      requesting = Thread.new do
        request.call(runtime)
      rescue Phronomy::PoolShutdownError => error
        error
      end
      await_signal(entered)
      expect(runtime.shutdown.cleanup_complete?).to be(true)
      release << true
      expect(requesting.join(2)).not_to be_nil
      result = requesting.value
      expect(result).to be_a(Phronomy::PoolShutdownError)
      expect(runtime.state).to eq(:terminated)
    ensure
      release << true
      requesting&.join(2)
      result ||= requesting.value if requesting && !requesting.alive?
      result.shutdown(drain_timeout: 1) if result.is_a?(Phronomy::Concurrency::OffloadPool)
      runtime&.shutdown
    end
  end

  it "allows admitted continuations to acquire resources while Runtime is draining" do
    runtime = Phronomy::Runtime.new
    draining = Queue.new
    release = Queue.new
    participant = double("participant", begin_draining: nil, after_runtime_shutdown: nil)
    allow(participant).to receive(:wait_until_idle) do |_deadline|
      draining << true
      await_signal(release)
      true
    end
    runtime.__register_shutdown_participant(key: :owner, participant: participant)
    stopping = Thread.new { runtime.shutdown(timeout: 1) }
    await_signal(draining)
    expect(runtime.state).to eq(:draining)
    pool = runtime.pool(:continuation, size: 1, queue_size: 1)
    expect(pool.submit(on_full: :raise) { :saved }.wait_result(timeout: 1)).to eq(:saved)
    release << true
    expect(stopping.join(2)).not_to be_nil
    expect(stopping.value.cleanup_complete?).to be(true)
  ensure
    release << true
    stopping&.join(2)
    pool&.shutdown(drain_timeout: 1)
    runtime&.shutdown
  end

  it "reports incomplete cleanup, retains Runtime and withholds finalization while workers remain" do
    runtime = Phronomy::Runtime.new
    previous = Phronomy::Runtime.replace_default_for_test(runtime)
    entered = Queue.new
    release = Queue.new
    pools = [runtime.offload(pool_size: 1, queue_size: 1), runtime.pool(:other, size: 1, queue_size: 1)]
    tasks = pools.map { |pool|
      pool.submit {
        entered << true
        await_signal(release)
        :finished
      }
    }
    2.times { await_signal(entered) }
    participant = Class.new do
      attr_reader :finalized

      def begin_draining = nil
      def wait_until_idle(_deadline) = true
      def after_runtime_shutdown = @finalized = true
    end.new
    runtime.__register_shutdown_participant(key: :owner, participant: participant)
    stopping = Thread.new { runtime.shutdown(timeout: 0, cancel_grace: 0) }
    expect(stopping.join(1)).not_to be_nil
    result = stopping.value
    expect(result.cleanup_complete?).to be(false)
    expect(result.clean?).to be(false)
    expect(runtime.state).to eq(:failed)
    expect(participant.finalized).not_to be(true)
    expect(tasks.map(&:status)).to eq([:pending, :pending])
    expect { Phronomy::Runtime.reset_default!(timeout: 0) }
      .to raise_error(Phronomy::RuntimeShutdownError, /cleanup is incomplete/)
    expect(Phronomy::Runtime.instance).to equal(runtime)
  ensure
    2.times { release << true }
    tasks&.each { |task| task.wait_result(timeout: 2) }
    stopping&.join(2)
    pools&.each { |pool| pool.shutdown(drain_timeout: 1) }
    Phronomy::Runtime.restore_default_for_test(previous)
  end

  it "keeps cleanup incomplete after logical cancellation until the worker physically returns" do
    runtime = Phronomy::Runtime.new
    pool = runtime.offload(pool_size: 1, queue_size: 1)
    token = Phronomy::Concurrency::CancellationToken.new
    entered = Queue.new
    release = Queue.new
    task = pool.submit(cancellation_token: token) {
      entered << true
      await_signal(release)
      :finished
    }
    await_signal(entered)
    token.cancel!
    expect(task.status).to eq(:cancelled)
    stopping = Thread.new { runtime.shutdown(timeout: 0, cancel_grace: 0) }
    expect(stopping.join(1)).not_to be_nil
    expect(stopping.value.cleanup_complete?).to be(false)
    expect(pool.active_count).to eq(1)
    release << true
    pool.shutdown(drain_timeout: 1)
    expect(pool.terminated?).to be(true)
    expect(task.status).to eq(:cancelled)
  ensure
    release << true
    stopping&.join(2)
    pool&.shutdown(drain_timeout: 1)
  end

  it "closes every pool before waiting on one pool's workers" do
    runtime = Phronomy::Runtime.new
    first = runtime.offload(pool_size: 1, queue_size: 1)
    second = runtime.pool(:second, size: 1, queue_size: 1)
    entered = Queue.new
    release = Queue.new
    allow(first).to receive(:shutdown).and_wrap_original do |original, **options|
      entered << true
      await_signal(release)
      original.call(**options)
    end
    stopping = Thread.new { runtime.shutdown(timeout: 1) }
    await_signal(entered)
    expect { second.submit(on_full: :raise) { :too_late } }
      .to raise_error(Phronomy::PoolShutdownError)
    release << true
    expect(stopping.join(2)).not_to be_nil
    expect(stopping.value.cleanup_complete?).to be(true)
  ensure
    release << true
    stopping&.join(2)
    allow(first).to receive(:shutdown).and_call_original if first
    first&.shutdown(drain_timeout: 1)
    second&.shutdown(drain_timeout: 1)
  end

  it "attempts all pool and timer cleanup when one pool shutdown raises" do
    runtime = Phronomy::Runtime.new
    first = runtime.offload(pool_size: 1, queue_size: 1)
    second = runtime.pool(:second, size: 1, queue_size: 1)
    timer = runtime.timer_queue
    allow(first).to receive(:shutdown).and_wrap_original do |original, **options|
      original.call(**options)
      raise IOError, "pool join failed"
    end
    expect(second).to receive(:shutdown).at_least(:once).and_call_original
    result = runtime.shutdown(timeout: 1)
    expect(result.cleanup_complete?).to be(false)
    expect(result.error.message).to eq("pool join failed")
    expect { timer.schedule(seconds: 1) {} }.to raise_error(Phronomy::PoolShutdownError)
    expect { second.submit { :too_late } }.to raise_error(Phronomy::PoolShutdownError)
  ensure
    allow(first).to receive(:shutdown).and_call_original if first
    first&.shutdown(drain_timeout: 1)
    second&.shutdown(drain_timeout: 1)
    runtime&.shutdown
  end
end
