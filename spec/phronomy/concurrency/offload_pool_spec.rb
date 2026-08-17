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
    it "executes synchronous work on a worker and returns a Task" do
      caller_thread = Thread.current
      worker_thread = nil
      task = pool.submit do
        worker_thread = Thread.current
        42
      end

      expect(task).to be_a(Phronomy::Task)
      expect(task.wait_result).to eq(42)
      expect(worker_thread).not_to be(caller_thread)
      expect(worker_thread.name).to include("phronomy-offload-pool")
    end

    it "supports CPU-bound synchronous work without a dedicated execution mode" do
      task = pool.submit { (1..10_000).sum }

      expect(task.wait_result).to eq(50_005_000)
    end

    it "re-raises errors from submitted work" do
      task = pool.submit { raise ArgumentError, "bad arg" }

      expect { task.wait_result }.to raise_error(ArgumentError, "bad arg")
      expect(task.status).to eq(:failed)
    end

    it "exposes done? through the shared Task completion contract" do
      release = Queue.new
      task = pool.submit do
        release.pop
        :done
      end

      expect(task).not_to be_done

      release << true
      expect(task.wait_result).to eq(:done)
      expect(task).to be_done
      expect(task.status).to eq(:completed)
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
    it "settles the Task without interrupting running work" do
      started = Queue.new
      release = Queue.new
      completed = Queue.new

      task = pool.submit(timeout: 5) do
        started << true
        release.pop
        completed << true
        :completed
      end
      started.pop
      timer.advance(5)

      expect { task.wait_result }.to raise_error(Phronomy::TimeoutError)
      expect(task.status).to eq(:failed)
      expect(pool.abandoned_count).to eq(1)
      expect(pool.abandoned_active_count).to eq(1)

      release << true
      expect(completed.pop).to be(true)

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
      until pool.abandoned_active_count.zero?
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep(0.001)
      end

      expect(pool.abandoned_count).to eq(1)
      expect(pool.abandoned_active_count).to eq(0)
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

      task = pool.submit(timeout: 5) { executed = true }
      timer.advance(5)
      2.times { release << true }

      expect { task.wait_result }.to raise_error(Phronomy::TimeoutError)
      expect(task.status).to eq(:failed)
      expect(pool.abandoned_count).to eq(0)
      expect(pool.abandoned_active_count).to eq(0)

      markers = 2.times.map do
        Queue.new.tap { |marker| pool.submit { marker << true } }
      end
      markers.each(&:pop)

      expect(executed).to be(false)
    end
  end

  describe "waiter-local timeout" do
    it "does not settle or abandon the Task" do
      release = Queue.new
      task = pool.submit do
        release.pop
        :done
      end

      expect { task.wait_result(timeout: 0.02) }
        .to raise_error(Phronomy::TimeoutError)
      expect(task).not_to be_done
      expect(pool.abandoned_count).to eq(0)

      release << true
      expect(task.wait_result).to eq(:done)
    end

    it "returns normally when the operation completes before the waiter timeout" do
      task = pool.submit { :done }

      expect(task.wait_result(timeout: 1)).to eq(:done)
      expect(task).to be_done
    end

    it "does not expose a waiter-local cancellation token" do
      task = pool.submit { :done }
      token = Phronomy::Concurrency::CancellationToken.new

      expect {
        task.wait_result(cancellation_token: token)
      }.to raise_error(ArgumentError, /unknown keyword/)
    end
  end

  describe "submit cancellation" do
    it "settles immediately and skips work when the token is already cancelled" do
      token = Phronomy::Concurrency::CancellationToken.new
      token.cancel!
      executed = false

      task = pool.submit(cancellation_token: token) { executed = true }

      expect(task).to be_done
      expect(task.status).to eq(:cancelled)
      expect { task.wait_result }.to raise_error(Phronomy::CancellationError)
      expect(pool.abandoned_count).to eq(0)
      expect(executed).to be(false)
    end

    it "settles a queued Task immediately and skips it when cancellation wins before start" do
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

      task = tiny_pool.submit(cancellation_token: token) { executed = true }
      task.on_complete { |value, error| events << [value, error] }

      token.cancel!

      value, error = events.pop
      expect(value).to be_nil
      expect(error).to be_a(Phronomy::CancellationError)
      expect(task).to be_done
      expect(task.status).to eq(:cancelled)
      expect(tiny_pool.abandoned_count).to eq(0)
      expect(tiny_pool.abandoned_active_count).to eq(0)

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

      task = tiny_pool.submit(cancellation_token: token) do
        started << true
        release.pop
        worker_side_effect << :finished
        :worker_result
      end
      task.on_complete { |value, error| events << [value, error] }

      started.pop
      token.cancel!

      value, error = events.pop
      expect(value).to be_nil
      expect(error).to be_a(Phronomy::CancellationError)
      expect(task).to be_done
      expect(task.status).to eq(:cancelled)
      expect(tiny_pool.abandoned_count).to eq(1)
      expect(tiny_pool.abandoned_active_count).to eq(1)
      expect { task.wait_result }.to raise_error(Phronomy::CancellationError)

      release << true
      expect(worker_side_effect.pop).to eq(:finished)

      worker_drained = Queue.new
      tiny_pool.submit { worker_drained << true }
      worker_drained.pop

      expect(events.size).to eq(0)
      expect(tiny_pool.abandoned_count).to eq(1)
      expect(tiny_pool.abandoned_active_count).to eq(0)
      expect { task.wait_result }.to raise_error(Phronomy::CancellationError)
    ensure
      release << true if defined?(release) && release
      tiny_pool&.shutdown(drain_timeout: 2)
    end

    it "promotes a monotonic cancellation deadline through the pool timer queue" do
      token = Phronomy::Concurrency::CancellationToken.timeout_after(60)
      started = Queue.new
      release = Queue.new
      events = Queue.new

      task = pool.submit(cancellation_token: token) do
        started << true
        release.pop
        :done
      end
      task.on_complete { |value, error| events << [value, error] }

      started.pop
      timer.advance(60)

      value, error = events.pop
      expect(value).to be_nil
      expect(error).to be_a(Phronomy::CancellationError)
      expect(token).to be_cancelled
      expect(task.status).to eq(:cancelled)
      expect(pool.abandoned_active_count).to eq(1)

      release << true
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
      until pool.abandoned_active_count.zero?
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep(0.001)
      end
      expect(pool.abandoned_active_count).to eq(0)
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
      task = pool.submit(cancellation_token: token) { :done }

      expect(task.wait_result).to eq(:done)
      expect(token.instance_variable_get(:@cancel_callbacks)).to be_empty
    end

    it "does not let late submit cancellation overwrite a completed result" do
      token = Phronomy::Concurrency::CancellationToken.new
      task = pool.submit(cancellation_token: token) { :done }

      expect(task.wait_result).to eq(:done)

      token.cancel!

      expect(task).to be_done
      expect(task.status).to eq(:completed)
      expect(task.wait_result).to eq(:done)
    end

    it "cancels every Task sharing a token even when one completion callback raises" do
      token = Phronomy::Concurrency::CancellationToken.new
      started = Array.new(2) { Queue.new }
      release = Queue.new
      second_events = Queue.new

      task1 = pool.submit(cancellation_token: token) do
        started[0] << true
        release.pop
        :first
      end
      task2 = pool.submit(cancellation_token: token) do
        started[1] << true
        release.pop
        :second
      end

      task1.on_complete { raise "completion callback boom" }
      task2.on_complete { |value, error| second_events << [value, error] }
      started.each(&:pop)

      expect { token.cancel! }.not_to raise_error

      value, error = second_events.pop
      expect(value).to be_nil
      expect(error).to be_a(Phronomy::CancellationError)
      expect(task1.status).to eq(:cancelled)
      expect(task2.status).to eq(:cancelled)
      expect(pool.abandoned_count).to eq(2)
      expect(pool.abandoned_active_count).to eq(2)
    ensure
      2.times { release << true } if defined?(release) && release
    end
  end

  describe "Task#on_complete" do
    it "delivers success" do
      events = []
      task = pool.submit { 42 }
      returned = task.on_complete { |value, error| events << [value, error] }

      expect(returned).to be(task)
      expect(task.wait_result).to eq(42)
      expect(events).to eq([[42, nil]])
    end

    it "delivers failure" do
      events = []
      task = pool.submit { raise "boom" }
      task.on_complete { |value, error| events << [value, error] }

      expect { task.wait_result }.to raise_error(RuntimeError, "boom")
      expect(events.first.first).to be_nil
      expect(events.first.last).to be_a(RuntimeError)
    end

    it "fires immediately and returns self when registered after settlement" do
      task = pool.submit { 42 }
      expect(task.wait_result).to eq(42)

      events = []
      returned = task.on_complete { |value, error| events << [value, error] }

      expect(returned).to be(task)
      expect(events).to eq([[42, nil]])
    end

    it "continues completion fan-out when one callback raises" do
      release = Queue.new
      observed = Queue.new
      task = pool.submit do
        release.pop
        :done
      end

      task.on_complete { raise "boom" }
      task.on_complete { |value, error| observed << [value, error] }

      release << true

      value, error = observed.pop
      expect(value).to eq(:done)
      expect(error).to be_nil
      expect(task.wait_result).to eq(:done)
    end

    it "isolates a callback registered after settlement" do
      task = pool.submit { :done }
      expect(task.wait_result).to eq(:done)

      expect {
        task.on_complete { raise "late boom" }
      }.not_to raise_error
      expect(task.wait_result).to eq(:done)
    end
  end

  describe "metrics" do
    it "exposes bounded-pool metrics" do
      pool.submit { 1 }.wait_result

      expect(pool.active_count).to eq(0)
      expect(pool.queue_depth).to be >= 0
      expect(pool.abandoned_count).to be >= 0
      expect(pool.abandoned_active_count).to be >= 0
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
