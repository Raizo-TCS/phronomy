# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Runtime shutdown deadlines" do
  def await_signal(queue)
    queue.pop(timeout: 2) || raise("shutdown deadline test barrier timed out")
  end

  def finish_worker(release, pool)
    release << true
    pool&.shutdown(drain_timeout: 2)
  end

  # Hold operation deadlines until resource shutdown reaches its pool join.
  # This distinguishes a live timer driver from a timer that fired before stop.
  def expire_when_pool_drains(runtime, pool)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    runtime.timer_queue.instance_variable_set(:@clock, -> { now })
    allow(pool).to receive(:shutdown).and_wrap_original do |original, **options|
      now += 1
      runtime.__event_loop_if_initialized.wake
      original.call(**options)
    end
  end

  it "preserves an in-flight Blocking timeout while pool shutdown waits" do
    runtime = Phronomy::Runtime.instance
    pool = runtime.offload
    expire_when_pool_drains(runtime, pool)
    entered = Queue.new
    release = Queue.new
    callback_threads = []
    task = Phronomy::Blocking.call_async(timeout: 0.05) do
      entered << true
      await_signal(release)
      :late_success
    end
    task.on_complete do
      callback_threads << runtime.event_loop_current?
      release << true
    end
    await_signal(entered)

    result = runtime.shutdown(timeout: 0, cancel_grace: 1)

    expect(task.status).to eq(:failed)
    expect { task.wait_result }.to raise_error(Phronomy::TimeoutError, /offloaded operation timed out/)
    expect(callback_threads).to eq([true])
    expect(result.cleanup_complete?).to be(true)
    expect(pool.terminated?).to be(true)
  ensure
    finish_worker(release, pool)
  end

  %i[default named].each do |kind|
    it "skips expired queued work in the #{kind} pool during shutdown" do
      runtime = Phronomy::Runtime.instance
      pool = if kind == :default
        runtime.offload(pool_size: 1, queue_size: 1)
      else
        runtime.pool(:deadline, size: 1, queue_size: 1)
      end
      expire_when_pool_drains(runtime, pool)
      entered = Queue.new
      release = Queue.new
      effects = []
      first = pool.submit do
        entered << true
        await_signal(release)
      end
      await_signal(entered)
      second = pool.submit(timeout: 0.05) { effects << :expired_work }
      second.on_complete { release << true }

      result = runtime.shutdown(timeout: 0, cancel_grace: 1)

      expect(second.status).to eq(:failed)
      expect { second.wait_result }.to raise_error(Phronomy::TimeoutError)
      expect(first.status).to eq(:completed)
      expect(effects).to be_empty
      expect(result.cleanup_complete?).to be(true)
      expect(pool.terminated?).to be(true)
    ensure
      finish_worker(release, pool)
    end
  end

  it "preserves a fan-out deadline while its physical child finishes" do
    runtime = Phronomy::Runtime.instance
    pool = runtime.offload
    expire_when_pool_drains(runtime, pool)
    entered = Queue.new
    release = Queue.new
    child = nil
    task = Phronomy::Execution.run_async([:job], timeout: 0.05) do
      child = Phronomy::Blocking.call_async do
        entered << true
        await_signal(release)
        :late_success
      end
    end
    task.on_complete { release << true }
    await_signal(entered)

    result = runtime.shutdown(timeout: 0, cancel_grace: 1)

    expect(task.status).to eq(:failed)
    expect { task.wait_result }.to raise_error(Phronomy::ExecutionTimeoutError) { |error|
      expect(error.outcomes.map(&:status)).to eq([:unfinished])
    }
    expect(child.wait_result).to eq(:late_success)
    expect(result.cleanup_complete?).to be(true)
  ensure
    finish_worker(release, pool)
  end

  it "delivers a deadline for fan-out without any pool work" do
    runtime = Phronomy::Runtime.instance
    child = Phronomy::TaskResult.deferred
    task = Phronomy::Execution.run_async([:job], timeout: 0.05) { child }

    result = runtime.shutdown(timeout: 0, cancel_grace: 1)

    expect(runtime.__offload_if_initialized).to be_nil
    expect(task.status).to eq(:failed)
    expect { task.wait_result }.to raise_error(Phronomy::ExecutionTimeoutError)
    expect(result.cleanup_complete?).to be(true)
  ensure
    child&.complete(:released)
  end

  it "wakes drain promptly when an early result removes its future deadline" do
    runtime = Phronomy::Runtime.instance
    child = Phronomy::TaskResult.deferred
    task = Phronomy::Execution.run_async([:job], timeout: 60) { child }
    waiting = Queue.new
    timer = runtime.timer_queue
    allow(timer).to receive(:wait_until_idle).and_wrap_original do |original, deadline|
      waiting << true
      original.call(deadline)
    end
    stopping = Thread.new { runtime.shutdown(timeout: 1, cancel_grace: 1) }
    await_signal(waiting)

    child.complete(:early_success)

    expect(stopping.join(0.5)).not_to be_nil
    expect(task.wait_result.map(&:value)).to eq([:early_success])
    expect(stopping.value.cleanup_complete?).to be(true)
  ensure
    child&.complete(:released)
    stopping&.join(2)
  end

  it "allows a timer continuation to acquire the timer service during drain" do
    runtime = Phronomy::Runtime.instance
    finished = Queue.new
    callback_threads = []
    Phronomy::Execution.after(0.01) do
      callback_threads << runtime.event_loop_current?
      Phronomy::Blocking.call_async(timeout: 1) { :continued }.on_complete { finished << true }
    end

    result = runtime.shutdown(timeout: 1, cancel_grace: 1)

    expect(result.cleanup_complete?).to be(true)
    expect(finished.pop(timeout: 0.1)).to be(true)
    expect(callback_threads).to eq([true])
  end

  it "preserves deadline-token cancellation during physical pool shutdown" do
    runtime = Phronomy::Runtime.instance
    entered = Queue.new
    release = Queue.new
    token = Phronomy::Concurrency::CancellationToken.timeout_after(0.05)
    task = Phronomy::Blocking.call_async(cancellation_token: token) do
      entered << true
      await_signal(release)
      :late_success
    end
    pool = runtime.__offload_if_initialized
    task.on_complete { release << true }
    await_signal(entered)

    result = runtime.shutdown(timeout: 0, cancel_grace: 1)

    expect(task.status).to eq(:cancelled)
    expect(result.cleanup_complete?).to be(true)
  ensure
    finish_worker(release, pool)
  end

  it "retains an incomplete Runtime when a future deadline exceeds the stop budget" do
    runtime = Phronomy::Runtime.instance
    child = Phronomy::TaskResult.deferred
    task = Phronomy::Execution.run_async([:job], timeout: 60) { child }
    effects = []
    Phronomy::Execution.after(60) { effects << :early_callback }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    result = runtime.shutdown(timeout: 0, cancel_grace: 0)

    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
    expect(result.cleanup_complete?).to be(false)
    expect(runtime.state).to eq(:failed)
    expect(runtime.shutdown).to equal(result)
    expect(effects).to be_empty
    expect(task.status).to eq(:pending)
    expect { Phronomy::Runtime.reset_default!(timeout: 0) }
      .to raise_error(Phronomy::RuntimeShutdownError, /cleanup is incomplete/)
    expect(Phronomy::Runtime.instance).to equal(runtime)
  ensure
    child&.complete(:released)
  end

  it "reports a timer registered between the idle observation and timer closure" do
    runtime = Phronomy::Runtime.instance
    timer = runtime.timer_queue
    loop_instance = runtime.__event_loop_if_initialized
    effects = []
    allow(loop_instance).to receive(:stop_and_join).and_wrap_original do |original, **options|
      timer.schedule(seconds: 60) { effects << :too_late }
      original.call(**options)
    end

    result = runtime.shutdown(timeout: 0, cancel_grace: 1)

    expect(result.cleanup_complete?).to be(false)
    expect(loop_instance.thread_alive?).to be(false)
    expect(effects).to be_empty
    expect { timer.schedule(seconds: 1) {} }.to raise_error(Phronomy::PoolShutdownError)
  end
end
