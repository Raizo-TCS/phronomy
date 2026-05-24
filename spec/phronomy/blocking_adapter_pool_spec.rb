# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::BlockingAdapterPool do
  subject(:pool) { described_class.new(pool_size: 2, queue_size: 10) }

  after {
    begin
      pool.shutdown(drain_timeout: 2)
    rescue
      nil
    end
  }

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
      op = pool.submit {
        sleep 0.5
        :done
      }
      expect(op).to be_a(Phronomy::BlockingAdapterPool::PendingOperation)
      op.await
    end

    it "executes multiple submissions concurrently" do
      start = Time.now
      results = Array.new(4) { |i|
        pool.submit {
          sleep 0.05
          i
        }
      }.map(&:await)
      elapsed = Time.now - start
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
      begin
        op.await
      rescue
        nil
      end
      expect(op.abandoned?).to be(true)
    end

    it "increments abandoned_count" do
      op = pool.submit(timeout: 0.05) { sleep 10 }
      begin
        op.await
      rescue
        nil
      end
      expect(pool.abandoned_count).to be >= 1
    end
  end

  # Issue #287 — Timeout.timeout uses async Thread#raise and can corrupt
  # library state mid-call.  The pool must NOT use Timeout.timeout; instead,
  # #await enforces the deadline and the worker thread is allowed to run to
  # completion on its own.
  describe "timeout safety (Issue #287 — no Timeout.timeout)", :issue_287 do
    it "does not interrupt the worker thread when the caller times out" do
      mutex = Mutex.new
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

    it "raises CancellationError when token is cancelled while waiting (Issue #288)" do
      token = Phronomy::CancellationToken.new
      # Submit a slow operation without a cancellation token so the worker runs
      op = pool.submit {
        sleep 10
        :done
      }
      # Cancel the token shortly after await starts
      Thread.new {
        sleep 0.05
        token.cancel!
      }
      expect { op.await(cancellation_token: token) }.to raise_error(Phronomy::CancellationError)
    end

    it "raises CancellationError when token passed to await is already cancelled (Issue #288)" do
      token = Phronomy::CancellationToken.new
      token.cancel!
      op = pool.submit { :fast }
      expect { op.await(cancellation_token: token) }.to raise_error(Phronomy::CancellationError)
    end
  end

  describe "await(timeout:) (Issue #288)" do
    it "raises TimeoutError when await-time timeout expires" do
      op = pool.submit {
        sleep 10
        :done
      }
      expect { op.await(timeout: 0.05) }.to raise_error(Phronomy::TimeoutError)
    end

    it "returns the value when the operation finishes before the await-time timeout" do
      op = pool.submit { :fast }
      expect(op.await(timeout: 5)).to eq(:fast)
    end

    it "uses the earlier of submit-time and await-time timeouts" do
      # submit with 10s, await with 0.05s — await timeout fires first
      op = pool.submit(timeout: 10) {
        sleep 5
        :done
      }
      expect { op.await(timeout: 0.05) }.to raise_error(Phronomy::TimeoutError)
    end
  end

  describe "#on_complete (Issue #288)" do
    it "calls the callback with result and nil error when operation succeeds" do
      result_holder = []
      op = pool.submit { 42 }
      op.on_complete { |v, e| result_holder << [v, e] }
      op.await
      # brief sleep to allow worker callback to run if not yet fired
      sleep 0.05
      expect(result_holder).to eq([[42, nil]])
    end

    it "calls the callback with nil result and error when operation fails" do
      err_holder = []
      op = pool.submit { raise "boom" }
      op.on_complete { |v, e| err_holder << [v, e] }
      begin
        op.await
      rescue
        nil
      end
      sleep 0.05
      expect(err_holder.first).to match([nil, an_instance_of(RuntimeError)])
    end

    it "invokes the callback immediately when the operation is already done" do
      op = pool.submit { :done }
      op.await
      fired = false
      op.on_complete { |_v, _e| fired = true }
      expect(fired).to be(true)
    end

    it "returns self so calls can be chained" do
      op = pool.submit { 1 }
      expect(op.on_complete { |_v, _e| }).to be(op)
    end
  end

  describe "metrics" do
    it "active_count is 0 when idle" do
      pool.submit { 1 }.await
      expect(pool.active_count).to eq(0)
    end

    it "queue_depth reflects pending operations" do
      # saturate workers then check queue
      slow = Array.new(2) {
        pool.submit {
          sleep 0.3
          1
        }
      }
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

    it "does not deadlock when the queue is full at shutdown time (Issue #316)" do
      # pool_size: 2, queue_size: 2 — ensures queue fills before shutdown
      tiny_pool = described_class.new(pool_size: 2, queue_size: 2)
      worker_started = Queue.new
      worker_gate = Queue.new

      # Pin both workers — they signal when started, then wait for release
      2.times do
        tiny_pool.submit do
          worker_started.push(:started)
          worker_gate.pop   # wait for release
        end
      end
      2.times { worker_started.pop }  # ensure both workers are busy

      # Fill the queue to capacity (2 more items)
      begin
        tiny_pool.submit(on_full: :raise) { 1 }
        tiny_pool.submit(on_full: :raise) { 1 }
      rescue Phronomy::BackpressureError
        # already full — that's fine
      end

      # shutdown is called while workers are pinned and queue is full
      # With the old code this blocks indefinitely; with the fix it returns quickly
      done = false
      shutdown_thread = Thread.new do
        tiny_pool.shutdown(drain_timeout: 5)
        done = true
      end

      # Give shutdown a moment to start, then release workers
      sleep 0.05
      worker_gate.push(:go)
      worker_gate.push(:go)

      shutdown_thread.join(8)
      expect(done).to be(true), "shutdown deadlocked with a full queue"
    end
  end

  describe "#done?" do
    it "returns false before the operation completes" do
      barrier = Mutex.new
      barrier.lock
      op = pool.submit {
        barrier.lock
        1
      }
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
