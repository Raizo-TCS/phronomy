# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Concurrency::OffloadPool do
  let(:timer) { Phronomy::Testing::FakeClock.new }

  subject(:pool) do
    described_class.new(
      pool_size: 2,
      queue_size: 10,
      timer_queue_provider: -> { timer }
    )
  end

  after do
    pool.shutdown(drain_timeout: 2)
  rescue
    nil
  end

  describe "#submit" do
    it "executes synchronous work on a worker and returns the value" do
      caller_thread = Thread.current
      worker_thread = nil
      op = pool.submit do
        worker_thread = Thread.current
        42
      end

      expect(op.blocking_wait).to eq(42)
      expect(worker_thread).not_to be(caller_thread)
      expect(worker_thread.name).to include("phronomy-offload-pool")
    end

    it "supports CPU-bound synchronous work without a dedicated execution mode" do
      op = pool.submit { (1..10_000).sum }
      expect(op.blocking_wait).to eq(50_005_000)
    end

    it "re-raises errors from submitted work" do
      op = pool.submit { raise ArgumentError, "bad arg" }
      expect { op.blocking_wait }.to raise_error(ArgumentError, "bad arg")
    end

    it "returns a PendingOperation immediately" do
      release = Queue.new
      op = pool.submit do
        release.pop
        :done
      end
      expect(op).to be_a(Phronomy::Concurrency::OffloadPool::PendingOperation)
      release << true
      expect(op.blocking_wait).to eq(:done)
    end

    it "never creates more worker threads than pool_size" do
      expect(pool.instance_variable_get(:@workers).size).to eq(2)
    end
  end

  describe "bounded queue admission" do
    it "raises BackpressureError with on_full: :raise instead of blocking the caller" do
      tiny_pool = described_class.new(pool_size: 1, queue_size: 1)
      started = Queue.new
      release = Queue.new

      tiny_pool.submit do
        started << true
        release.pop
      end
      started.pop
      tiny_pool.submit(on_full: :raise) { :queued }

      expect {
        tiny_pool.submit(on_full: :raise) { :rejected }
      }.to raise_error(Phronomy::BackpressureError, /OffloadPool queue is full/)
    ensure
      release << true if defined?(release) && release
      tiny_pool&.shutdown(drain_timeout: 2)
    end

    it "keeps named pools independent from the default pool" do
      runtime = Phronomy::Runtime.new
      default_pool = runtime.offload(pool_size: 1, queue_size: 1)
      cpu_pool = runtime.pool(:cpu, size: 1, queue_size: 1)

      expect(cpu_pool).not_to be(default_pool)
      expect(cpu_pool.name).to eq(:cpu)
      expect(default_pool.name).to eq(:default)
    ensure
      runtime&.shutdown(timeout: 2)
    end
  end

  describe "submit-time timeout" do
    it "settles the caller-facing operation without interrupting running work" do
      started = Queue.new
      release = Queue.new
      completed = Queue.new

      op = pool.submit(timeout: 5) do
        started << true
        release.pop
        completed << true
        :completed
      end
      started.pop
      timer.advance(5)

      expect { op.blocking_wait }.to raise_error(Phronomy::TimeoutError)
      expect(op).to be_timed_out
      expect(op).to be_abandoned
      expect(pool.abandoned_count).to eq(1)

      release << true
      expect(completed.pop).to be(true)
    end

    it "skips work that times out before worker execution starts" do
      started = Queue.new
      release = Queue.new
      executed = false

      2.times do
        pool.submit do
          started << true
          release.pop
        end
      end
      2.times { started.pop }

      op = pool.submit(timeout: 5) { executed = true }
      timer.advance(5)
      2.times { release << true }

      expect { op.blocking_wait }.to raise_error(Phronomy::TimeoutError)
      sleep 0.02
      expect(executed).to be(false)
      expect(op).not_to be_abandoned
    end
  end

  describe "waiter-local timeout" do
    it "does not settle or abandon the operation" do
      release = Queue.new
      op = pool.submit do
        release.pop
        :done
      end

      expect { op.blocking_wait(timeout: 0.02) }
        .to raise_error(Phronomy::TimeoutError)
      expect(op).not_to be_done
      expect(op).not_to be_abandoned

      release << true
      expect(op.blocking_wait).to eq(:done)
    end
  end

  describe "cancellation" do
    it "skips work when the token was cancelled before execution" do
      token = Phronomy::Concurrency::CancellationToken.new
      token.cancel!
      op = pool.submit(cancellation_token: token) { :never_runs }
      expect { op.blocking_wait }.to raise_error(Phronomy::CancellationError)
    end

    it "does not forcibly interrupt a worker after execution starts" do
      token = Phronomy::Concurrency::CancellationToken.new
      started = Queue.new
      release = Queue.new
      completed = Queue.new
      op = pool.submit(cancellation_token: token) do
        started << true
        release.pop
        completed << true
        :done
      end

      started.pop
      token.cancel!
      release << true
      expect(completed.pop).to be(true)
      expect(op.blocking_wait).to eq(:done)
    end
  end

  describe "#on_complete" do
    it "delivers success" do
      events = []
      op = pool.submit { 42 }
      op.on_complete { |value, error| events << [value, error] }
      expect(op.blocking_wait).to eq(42)
      expect(events).to eq([[42, nil]])
    end

    it "delivers failure" do
      events = []
      op = pool.submit { raise "boom" }
      op.on_complete { |value, error| events << [value, error] }
      expect { op.blocking_wait }.to raise_error(RuntimeError, "boom")
      expect(events.first.first).to be_nil
      expect(events.first.last).to be_a(RuntimeError)
    end
  end

  describe "metrics" do
    it "exposes bounded-pool metrics" do
      pool.submit { 1 }.blocking_wait
      expect(pool.active_count).to eq(0)
      expect(pool.queue_depth).to be >= 0
      expect(pool.abandoned_count).to be >= 0
      expect(pool.average_wait_seconds).to be >= 0.0
      expect(pool.pool_size).to eq(2)
      expect(pool.queue_size).to eq(10)
    end
  end

  describe "#shutdown" do
    it "rejects subsequent submissions" do
      pool.shutdown
      expect { pool.submit { 1 } }.to raise_error(Phronomy::PoolShutdownError)
    end

    it "does not deadlock when the queue is full" do
      tiny_pool = described_class.new(pool_size: 1, queue_size: 1)
      started = Queue.new
      release = Queue.new
      tiny_pool.submit do
        started << true
        release.pop
      end
      started.pop
      tiny_pool.submit(on_full: :raise) { :queued }

      done = false
      shutdown_thread = Thread.new do
        tiny_pool.shutdown(drain_timeout: 2)
        done = true
      end
      sleep 0.02
      release << true
      shutdown_thread.join(3)
      expect(done).to be(true)
    ensure
      tiny_pool&.shutdown(drain_timeout: 1)
    end
  end
end

RSpec.describe "Runtime#offload" do
  it "returns the same default OffloadPool on repeated calls" do
    runtime = Phronomy::Runtime.new
    expect(runtime.offload).to be(runtime.offload)
    expect(runtime.offload).to be_a(Phronomy::Concurrency::OffloadPool)
  ensure
    runtime&.shutdown(timeout: 2)
  end
end
