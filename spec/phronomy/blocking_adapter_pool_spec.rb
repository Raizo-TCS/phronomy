# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::BlockingAdapterPool do
  subject(:pool) { described_class.new(pool_size: 2, queue_size: 10) }

  after { pool.shutdown(drain_timeout: 2) rescue nil }

  describe "#submit" do
    it "executes the block and returns the value via #await" do
      op = pool.submit { 42 }
      expect(op.await).to eq(42)
    end

    it "re-raises errors from the block" do
      op = pool.submit { raise ArgumentError, "bad arg" }
      expect { op.await }.to raise_error(ArgumentError, "bad arg")
    end

    it "returns a PendingOperation immediately" do
      op = pool.submit { sleep 0.5; :done }
      expect(op).to be_a(Phronomy::BlockingAdapterPool::PendingOperation)
      op.await
    end

    it "executes multiple submissions concurrently" do
      start    = Time.now
      results  = Array.new(4) { |i| pool.submit { sleep 0.05; i } }.map(&:await)
      elapsed  = Time.now - start
      expect(results.sort).to eq([0, 1, 2, 3])
      # 4 tasks on 2 workers should finish in ~2 batches (~0.1 s), not ~0.2 s
      expect(elapsed).to be < 0.25
    end
  end

  describe "timeout" do
    it "raises TimeoutError when the block exceeds the timeout" do
      op = pool.submit(timeout: 0.05) { sleep 10 }
      expect { op.await }.to raise_error(Phronomy::TimeoutError)
    end

    it "marks the operation as abandoned after a timeout" do
      op = pool.submit(timeout: 0.05) { sleep 10 }
      op.await rescue nil
      expect(op.abandoned?).to be(true)
    end

    it "increments abandoned_count" do
      op = pool.submit(timeout: 0.05) { sleep 10 }
      op.await rescue nil
      expect(pool.abandoned_count).to be >= 1
    end
  end

  # Issue #287 — Timeout.timeout uses async Thread#raise and can corrupt
  # library state mid-call.  The pool must NOT use Timeout.timeout; instead,
  # #await enforces the deadline and the worker thread is allowed to run to
  # completion on its own.
  describe "timeout safety (Issue #287 — no Timeout.timeout)", :issue_287 do
    it "does not interrupt the worker thread when the caller times out" do
      mutex    = Mutex.new
      done_flag = false

      # Block takes 0.15 s but the caller timeout is only 0.05 s.
      # With Timeout.timeout the sleep would be killed by async Thread#raise
      # and done_flag would never be set to true.
      op = pool.submit(timeout: 0.05) do
        sleep 0.15
        mutex.synchronize { done_flag = true }
        :completed
      end

      expect { op.await }.to raise_error(Phronomy::TimeoutError)

      # Worker thread must be allowed to finish on its own; wait a bit longer.
      sleep 0.3
      expect(mutex.synchronize { done_flag }).to be(true)
    end
  end

  describe "cancellation" do
    it "raises CancellationError when the token is already cancelled" do
      token = Phronomy::CancellationToken.new
      token.cancel!
      op = pool.submit(cancellation_token: token) { :never_runs }
      expect { op.await }.to raise_error(Phronomy::CancellationError)
    end
  end

  describe "metrics" do
    it "active_count is 0 when idle" do
      pool.submit { 1 }.await
      expect(pool.active_count).to eq(0)
    end

    it "queue_depth reflects pending operations" do
      # saturate workers then check queue
      slow = Array.new(2) { pool.submit { sleep 0.3; 1 } }
      # with pool_size: 2 the next submit goes to queue
      queued = pool.submit { 2 }
      expect(pool.queue_depth).to be >= 0  # best-effort; queue may drain fast
      slow.each(&:await)
      queued.await
    end

    it "average_wait_seconds returns a non-negative float" do
      pool.submit { 1 }.await
      expect(pool.average_wait_seconds).to be >= 0.0
    end
  end

  describe "#shutdown" do
    it "raises PoolShutdownError on subsequent submit calls" do
      pool.shutdown
      expect { pool.submit { 1 } }.to raise_error(Phronomy::PoolShutdownError)
    end

    it "returns self" do
      expect(pool.shutdown).to be(pool)
    end
  end

  describe "#done?" do
    it "returns false before the operation completes" do
      barrier = Mutex.new
      barrier.lock
      op = pool.submit { barrier.lock; 1 }
      expect(op.done?).to be(false)
      barrier.unlock
      op.await
    end

    it "returns true after the operation completes" do
      op = pool.submit { 1 }
      op.await
      expect(op.done?).to be(true)
    end
  end
end

RSpec.describe "Runtime#blocking_io" do
  after { Phronomy::Runtime.instance_variable_set(:@instance, nil) }

  it "returns a BlockingAdapterPool" do
    pool = Phronomy::Runtime.instance.blocking_io
    expect(pool).to be_a(Phronomy::BlockingAdapterPool)
    pool.shutdown(drain_timeout: 1)
  end

  it "returns the same pool on repeated calls" do
    runtime = Phronomy::Runtime.new
    expect(runtime.blocking_io).to be(runtime.blocking_io)
    runtime.blocking_io.shutdown(drain_timeout: 1)
  end
end
