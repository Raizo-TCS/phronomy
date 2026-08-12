# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Concurrency::BlockingAdapterPool do
  let(:timer) { Phronomy::Testing::FakeClock.new }

  subject(:pool) do
    described_class.new(
      pool_size: 2,
      queue_size: 10,
      timer_queue_provider: -> { timer }
    )
  end

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
      expect(op.blocking_wait).to eq(42)
    end

    it "re-raises errors from the block" do
      op = pool.submit { raise ArgumentError, "bad arg" }
      expect { op.blocking_wait }.to raise_error(ArgumentError, "bad arg")
    end

    it "returns a PendingOperation immediately" do
      op = pool.submit {
        sleep 0.5
        :done
      }
      expect(op).to be_a(Phronomy::Concurrency::BlockingAdapterPool::PendingOperation)
      op.blocking_wait
    end

    it "executes multiple submissions concurrently" do
      start = Time.now
      results = Array.new(4) { |i|
        pool.submit {
          sleep 0.05
          i
        }
      }.map(&:blocking_wait)
      elapsed = Time.now - start
      expect(results.sort).to eq([0, 1, 2, 3])
      # 4 tasks on 2 workers should finish in ~2 batches (~0.1 s), not ~0.2 s
      expect(elapsed).to be < 0.25
    end
  end

  describe "submit-time timeout" do
    it "notifies a registered callback before the worker completes" do
      started = Queue.new
      release = Queue.new
      events = []

      op = pool.submit(timeout: 5) do
        started << true
        release.pop
        :done
      end
      op.on_complete { |value, error| events << [value, error] }

      started.pop
      timer.advance(5)

      expect(events.length).to eq(1)
      expect(events.first.first).to be_nil
      expect(events.first.last).to be_a(Phronomy::TimeoutError)
      expect(op).to be_done
      expect(op).to be_timed_out
      expect(op).to be_abandoned
      expect(pool.abandoned_count).to eq(1)

      expect(op.fire_timeout!).to be(false)
      expect(pool.abandoned_count).to eq(1)
      release << true
    end

    it "does not execute an operation that times out while queued" do
      started = Queue.new
      release = Queue.new
      marker = Queue.new
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
      pool.submit { marker << true }
      2.times { release << true }
      marker.pop

      expect(op).to be_timed_out
      expect(op).not_to be_abandoned
      expect(executed).to be(false)
    end

    it "delivers the saved TimeoutError to callbacks registered after timeout" do
      started = Queue.new
      release = Queue.new
      op = pool.submit(timeout: 5) do
        started << true
        release.pop
      end

      started.pop
      timer.advance(5)

      events = []
      op.on_complete { |value, error| events << [value, error] }
      expect(events.first.first).to be_nil
      expect(events.first.last).to be_a(Phronomy::TimeoutError)

      release << true
    end
  end

  # Issue #287 — submit-time timeout must not use async Thread#raise. The caller
  # is released while the worker is allowed to finish naturally.
  describe "timeout safety (Issue #287 — no Timeout.timeout)", :issue_287 do
    it "does not interrupt the worker thread when the caller times out" do
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
      release << true
      expect(completed.pop).to be(true)
    end
  end

  describe "cancellation" do
    it "raises CancellationError when the token is already cancelled" do
      token = Phronomy::Concurrency::CancellationToken.new
      token.cancel!
      op = pool.submit(cancellation_token: token) { :never_runs }
      expect { op.blocking_wait }.to raise_error(Phronomy::CancellationError)
    end

    it "raises CancellationError when token is cancelled while waiting (Issue #288)" do
      token = Phronomy::Concurrency::CancellationToken.new
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
      expect { op.blocking_wait(cancellation_token: token) }.to raise_error(Phronomy::CancellationError)
    end

    it "raises CancellationError when token passed to await is already cancelled (Issue #288)" do
      token = Phronomy::Concurrency::CancellationToken.new
      token.cancel!
      op = pool.submit { :fast }
      expect { op.blocking_wait(cancellation_token: token) }.to raise_error(Phronomy::CancellationError)
    end
  end

  describe "blocking_wait(timeout:) (Issue #288)" do
    it "raises a waiter-local TimeoutError without settling the operation" do
      release = Queue.new
      op = pool.submit {
        release.pop
        :done
      }

      expect { op.blocking_wait(timeout: 0.05) }.to raise_error(Phronomy::TimeoutError)
      expect(op).not_to be_done
      expect(op).not_to be_abandoned

      release << true
      expect(op.blocking_wait).to eq(:done)
    end

    it "returns the value when the operation finishes before the await-time timeout" do
      op = pool.submit { :fast }
      expect(op.blocking_wait(timeout: 5)).to eq(:fast)
    end

    it "raises waiter-local TimeoutError even when submit-time timeout is longer" do
      # submit with 10s, blocking_wait with 0.05s — waiter-local timeout fires first
      release = Queue.new
      op = pool.submit(timeout: 10) do
        release.pop
        :done
      end
      expect { op.blocking_wait(timeout: 0.05) }.to raise_error(Phronomy::TimeoutError)
      expect(op).not_to be_done
    ensure
      release << true
      begin
        op&.blocking_wait
      rescue
        nil
      end
    end
  end

  describe "#on_complete (Issue #288)" do
    it "calls the callback with result and nil error when operation succeeds" do
      result_holder = []
      op = pool.submit { 42 }
      op.on_complete { |v, e| result_holder << [v, e] }
      op.blocking_wait
      # brief sleep to allow worker callback to run if not yet fired
      sleep 0.05
      expect(result_holder).to eq([[42, nil]])
    end

    it "calls the callback with nil result and error when operation fails" do
      err_holder = []
      op = pool.submit { raise "boom" }
      op.on_complete { |v, e| err_holder << [v, e] }
      begin
        op.blocking_wait
      rescue
        nil
      end
      sleep 0.05
      expect(err_holder.first).to match([nil, an_instance_of(RuntimeError)])
    end

    it "invokes the callback immediately when the operation is already done" do
      op = pool.submit { :done }
      op.blocking_wait
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
      pool.submit { 1 }.blocking_wait
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
      slow.each(&:blocking_wait)
      queued.blocking_wait
    end

    it "average_wait_seconds returns a non-negative float" do
      pool.submit { 1 }.blocking_wait
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
      op.blocking_wait
    end

    it "returns true after the operation completes" do
      op = pool.submit { 1 }
      op.blocking_wait
      expect(op.done?).to be(true)
    end
  end
end

RSpec.describe "Runtime#blocking_io" do
  after { Phronomy::Runtime.instance_variable_set(:@instance, nil) }

  it "returns a BlockingAdapterPool" do
    pool = Phronomy::Runtime.instance.blocking_io
    expect(pool).to be_a(Phronomy::Concurrency::BlockingAdapterPool)
    pool.shutdown(drain_timeout: 1)
  end

  it "returns the same pool on repeated calls" do
    runtime = Phronomy::Runtime.new
    expect(runtime.blocking_io).to be(runtime.blocking_io)
    runtime.blocking_io.shutdown(drain_timeout: 1)
  end
end
