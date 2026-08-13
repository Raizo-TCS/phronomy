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

      expect(op).to be_a(described_class::PendingOperation)

      release << true
      expect(op.blocking_wait).to eq(:done)
    end

    it "exposes done? as caller-facing settlement state" do
      release = Queue.new
      op = pool.submit do
        release.pop
        :done
      end

      expect(op).not_to be_done

      release << true
      expect(op.blocking_wait).to eq(:done)
      expect(op).to be_done
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
      expect(op).not_to be_cancelled
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
      expect(op).to be_timed_out
      expect(op).not_to be_cancelled
      expect(op).not_to be_abandoned

      # Drain both workers through one marker per worker before checking whether
      # the timed-out queued block was skipped.
      markers = 2.times.map do
        Queue.new.tap { |marker| pool.submit { marker << true } }
      end
      markers.each(&:pop)

      expect(executed).to be(false)
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

    it "returns normally when the operation completes before the waiter timeout" do
      op = pool.submit { :done }

      expect(op.blocking_wait(timeout: 1)).to eq(:done)
      expect(op).to be_done
    end
  end

  describe "submit cancellation" do
    it "settles immediately and skips work when the token is already cancelled" do
      token = Phronomy::Concurrency::CancellationToken.new
      token.cancel!
      executed = false

      op = pool.submit(cancellation_token: token) { executed = true }

      expect(op).to be_done
      expect(op).to be_cancelled
      expect(op).not_to be_timed_out
      expect(op).not_to be_abandoned
      expect { op.blocking_wait }.to raise_error(Phronomy::CancellationError)
      expect(executed).to be(false)
    end

    it "settles a queued operation immediately and skips it when cancellation wins before start" do
      tiny_pool = described_class.new(
        pool_size: 1,
        queue_size: 2,
        timer_queue_provider: -> { timer }
      )
      blocker_started = Queue.new
      blocker_release = Queue.new
      token = Phronomy::Concurrency::CancellationToken.new
      executed = false
      events = Queue.new

      tiny_pool.submit do
        blocker_started << true
        blocker_release.pop
      end
      blocker_started.pop

      op = tiny_pool.submit(cancellation_token: token) { executed = true }
      op.on_complete { |value, error| events << [value, error] }

      token.cancel!

      value, error = events.pop
      expect(value).to be_nil
      expect(error).to be_a(Phronomy::CancellationError)
      expect(op).to be_done
      expect(op).to be_cancelled
      expect(op).not_to be_abandoned
      expect(tiny_pool.abandoned_count).to eq(0)

      marker = Queue.new
      blocker_release << true
      tiny_pool.submit { marker << true }
      marker.pop

      expect(executed).to be(false)
    ensure
      blocker_release << true if defined?(blocker_release) && blocker_release
      tiny_pool&.shutdown(drain_timeout: 2)
    end

    it "settles on_complete immediately after start without forcibly interrupting the worker" do
      tiny_pool = described_class.new(
        pool_size: 1,
        queue_size: 2,
        timer_queue_provider: -> { timer }
      )
      token = Phronomy::Concurrency::CancellationToken.new
      started = Queue.new
      release = Queue.new
      worker_side_effect = Queue.new
      events = Queue.new

      op = tiny_pool.submit(cancellation_token: token) do
        started << true
        release.pop
        worker_side_effect << :finished
        :worker_result
      end
      op.on_complete { |value, error| events << [value, error] }

      started.pop
      token.cancel!

      value, error = events.pop
      expect(value).to be_nil
      expect(error).to be_a(Phronomy::CancellationError)
      expect(op).to be_done
      expect(op).to be_cancelled
      expect(op).to be_abandoned
      expect(tiny_pool.abandoned_count).to eq(1)
      expect { op.blocking_wait }.to raise_error(Phronomy::CancellationError)

      # Cancellation settles only the handle. The synchronous worker is allowed to
      # finish, and its eventual value must not re-settle the operation.
      release << true
      expect(worker_side_effect.pop).to eq(:finished)

      worker_drained = Queue.new
      tiny_pool.submit { worker_drained << true }
      worker_drained.pop

      expect(events.size).to eq(0)
      expect { op.blocking_wait }.to raise_error(Phronomy::CancellationError)
    ensure
      release << true if defined?(release) && release
      tiny_pool&.shutdown(drain_timeout: 2)
    end

    it "promotes a monotonic cancellation deadline through the pool timer queue" do
      token = Phronomy::Concurrency::CancellationToken.timeout_after(60)
      started = Queue.new
      release = Queue.new
      events = Queue.new

      op = pool.submit(cancellation_token: token) do
        started << true
        release.pop
        :done
      end
      op.on_complete { |value, error| events << [value, error] }

      started.pop
      timer.advance(60)

      value, error = events.pop
      expect(value).to be_nil
      expect(error).to be_a(Phronomy::CancellationError)
      expect(token).to be_cancelled
      expect(op).to be_cancelled
      expect(op).to be_abandoned

      release << true
    end

    it "requires a timer provider for a future monotonic cancellation deadline" do
      no_timer_pool = described_class.new(pool_size: 1, queue_size: 1)
      token = Phronomy::Concurrency::CancellationToken.timeout_after(60)

      expect {
        no_timer_pool.submit(cancellation_token: token) { :never_runs }
      }.to raise_error(Phronomy::ConfigurationError, /timer_queue/)
    ensure
      no_timer_pool&.shutdown(drain_timeout: 1)
    end

    it "detaches the submit cancellation callback after normal completion" do
      token = Phronomy::Concurrency::CancellationToken.new
      op = pool.submit(cancellation_token: token) { :done }

      expect(op.blocking_wait).to eq(:done)
      expect(token.instance_variable_get(:@cancel_callbacks)).to be_empty
    end

    it "does not let late submit cancellation overwrite a completed result" do
      token = Phronomy::Concurrency::CancellationToken.new
      op = pool.submit(cancellation_token: token) { :done }

      expect(op.blocking_wait).to eq(:done)

      token.cancel!

      expect(op).to be_done
      expect(op).not_to be_cancelled
      expect(op.blocking_wait).to eq(:done)
    end
  end

  describe "waiter-local cancellation" do
    it "wakes a blocked waiter without settling or interrupting the operation" do
      release = Queue.new
      op = pool.submit do
        release.pop
        :done
      end

      waiter_token = Phronomy::Concurrency::CancellationToken.new
      waiter_started = Queue.new
      waiter_result = Queue.new

      waiter = Thread.new do
        waiter_started << true
        begin
          waiter_result << op.blocking_wait(cancellation_token: waiter_token)
        rescue => error
          waiter_result << error
        end
      end

      waiter_started.pop
      waiter_token.cancel!

      expect(waiter_result.pop).to be_a(Phronomy::CancellationError)
      waiter.join(1)
      expect(waiter).not_to be_alive
      expect(op).not_to be_done
      expect(op).not_to be_abandoned

      release << true
      expect(op.blocking_wait).to eq(:done)
    ensure
      release << true if defined?(release) && release
      waiter&.join(1)
    end

    it "detaches the waiter-local cancellation callback when the wait finishes" do
      waiter_token = Phronomy::Concurrency::CancellationToken.new
      op = pool.submit { :done }

      expect(op.blocking_wait(cancellation_token: waiter_token)).to eq(:done)
      expect(waiter_token.instance_variable_get(:@cancel_callbacks)).to be_empty
    end

    it "raises immediately for an already-cancelled waiter token without changing the operation" do
      release = Queue.new
      op = pool.submit do
        release.pop
        :done
      end
      waiter_token = Phronomy::Concurrency::CancellationToken.new.cancel!

      expect {
        op.blocking_wait(cancellation_token: waiter_token)
      }.to raise_error(Phronomy::CancellationError)

      expect(op).not_to be_done
      expect(op).not_to be_abandoned

      release << true
      expect(op.blocking_wait).to eq(:done)
    end
  end

  describe "#on_complete" do
    it "delivers success" do
      events = []
      op = pool.submit { 42 }
      returned = op.on_complete { |value, error| events << [value, error] }

      expect(returned).to be(op)
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

    it "fires immediately and returns self when registered after settlement" do
      op = pool.submit { 42 }
      expect(op.blocking_wait).to eq(42)

      events = []
      returned = op.on_complete { |value, error| events << [value, error] }

      expect(returned).to be(op)
      expect(events).to eq([[42, nil]])
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
    it "returns self" do
      expect(pool.shutdown).to be(pool)
    end

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
