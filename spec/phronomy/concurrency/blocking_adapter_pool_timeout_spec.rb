# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Concurrency::BlockingAdapterPool, "submit-time timeout semantics" do
  let(:timer) { Phronomy::Testing::FakeClock.new }

  subject(:pool) do
    described_class.new(
      pool_size: 1,
      queue_size: 10,
      timer_queue_provider: -> { timer }
    )
  end

  after do
    pool.shutdown(drain_timeout: 2)
  rescue
    nil
  end

  it "fires a registered on_complete callback before the worker completes" do
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
    expect(events[0][0]).to be_nil
    expect(events[0][1]).to be_a(Phronomy::TimeoutError)
    expect(op).to be_done
    expect(op).to be_timed_out
    expect(op).to be_abandoned

    release << true
  end

  it "does not fire on_complete twice after the worker eventually completes" do
    started = Queue.new
    release = Queue.new
    marker = Queue.new
    events = []

    op = pool.submit(timeout: 5) do
      started << true
      release.pop
      :done
    end
    op.on_complete { |value, error| events << [value, error] }

    started.pop
    timer.advance(5)

    pool.submit { marker << true }
    release << true
    marker.pop

    expect(events.length).to eq(1)
    expect(events.first.last).to be_a(Phronomy::TimeoutError)
  end

  it "does not abandon when the worker completes before the submit deadline" do
    op = pool.submit(timeout: 5) { :ok }

    expect(op.blocking_wait).to eq(:ok)

    events = []
    op.on_complete { |value, error| events << [value, error] }

    expect(events).to eq([[:ok, nil]])
    expect(op).to be_done
    expect(op).not_to be_timed_out
    expect(op).not_to be_abandoned
  end

  it "fires immediately with TimeoutError when on_complete is registered after timeout" do
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

    expect(events.length).to eq(1)
    expect(events[0][0]).to be_nil
    expect(events[0][1]).to be_a(Phronomy::TimeoutError)

    release << true
  end

  it "does not execute the block when timeout fires before worker pickup" do
    blocker_started = Queue.new
    blocker_release = Queue.new
    marker = Queue.new
    executed = false

    pool.submit do
      blocker_started << true
      blocker_release.pop
    end
    blocker_started.pop

    op = pool.submit(timeout: 5) { executed = true }
    timer.advance(5)

    pool.submit { marker << true }
    blocker_release << true
    marker.pop

    expect(op).to be_done
    expect(op).to be_timed_out
    expect(op).not_to be_abandoned
    expect(executed).to be(false)
  end

  it "increments abandoned_count once for a running timeout" do
    started = Queue.new
    release = Queue.new

    op = pool.submit(timeout: 5) do
      started << true
      release.pop
    end

    started.pop
    timer.advance(5)

    expect(op.fire_timeout!).to be(false)
    expect(op).to be_abandoned
    expect(pool.abandoned_count).to eq(1)

    release << true
  end

  it "does not increment abandoned_count when timeout fires before execution" do
    blocker_started = Queue.new
    blocker_release = Queue.new
    marker = Queue.new

    pool.submit do
      blocker_started << true
      blocker_release.pop
    end
    blocker_started.pop

    op = pool.submit(timeout: 5) { :unreachable }
    pool.submit { marker << true }

    timer.advance(5)
    blocker_release << true
    marker.pop

    expect(op).to be_timed_out
    expect(op).not_to be_abandoned
    expect(pool.abandoned_count).to eq(0)
  end

  it "treats blocking_wait(timeout:) as a waiter-local timeout" do
    release = Queue.new
    op = pool.submit do
      release.pop
      :ok
    end

    expect {
      op.blocking_wait(timeout: 0.01)
    }.to raise_error(Phronomy::TimeoutError)

    expect(op).not_to be_done
    expect(op).not_to be_timed_out
    expect(op).not_to be_abandoned

    release << true
    expect(op.blocking_wait).to eq(:ok)
  end

  it "does not execute a block cancelled before worker execution" do
    token = Phronomy::Concurrency::CancellationToken.new
    token.cancel!
    executed = false

    op = pool.submit(cancellation_token: token) { executed = true }

    expect { op.blocking_wait }.to raise_error(Phronomy::CancellationError)
    expect(executed).to be(false)
  end

  it "still notifies on_complete when on_abandoned raises" do
    started = Queue.new
    release = Queue.new
    events = []

    op = described_class::PendingOperation.new(
      -> {
        started << true
        release.pop
      },
      timeout: 5,
      on_abandoned: -> { raise "metrics failed" }
    )
    op.on_complete { |value, error| events << [value, error] }

    worker = Thread.new { op.execute! }
    started.pop

    expect { op.fire_timeout! }.not_to raise_error
    expect(events.length).to eq(1)
    expect(events.first.last).to be_a(Phronomy::TimeoutError)
    expect(op).to be_done
    expect(op).to be_abandoned

    release << true
    worker.join
  end

  it "raises ConfigurationError when timeout is specified without a timer provider" do
    no_timer_pool = described_class.new(
      pool_size: 1,
      queue_size: 10,
      timer_queue_provider: nil
    )

    expect {
      no_timer_pool.submit(timeout: 5) { :ok }
    }.to raise_error(Phronomy::ConfigurationError)
  ensure
    no_timer_pool&.shutdown(drain_timeout: 1)
  end

  it "makes fail_submission! idempotent and prevents a later timeout" do
    op = described_class::PendingOperation.new(
      -> { :unused },
      timeout: 5
    )
    error = Phronomy::BackpressureError.new("queue full")

    expect(op.fail_submission!(error)).to be(true)
    expect(op.fail_submission!(error)).to be(false)
    expect(op.fire_timeout!).to be(false)
    expect(op).to be_done
    expect(op).not_to be_timed_out
  end
end
