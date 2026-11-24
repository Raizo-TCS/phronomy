# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Concurrency::OffloadPool, "positive submission refusal" do
  let(:timer) { Phronomy::Testing::FakeClock.new }
  let(:pool) do
    described_class.new(pool_size: 1, queue_size: 1,
      timer_queue_provider: -> { timer })
  end
  let(:refusals) { [] }
  let(:receiver) { ->(error) { refusals << [error, Thread.current] } }

  after do
    @release&.push(true)
    pool.shutdown(drain_timeout: 2)
  end

  def fill_queue
    started = Queue.new
    @release = Queue.new
    pool.submit do
      started << true
      @release.pop
    end
    raise "blocking worker did not start" unless started.pop(timeout: 3)
    pool.submit(on_full: :raise) { :already_queued }
  end

  it "reports actual queue refusal synchronously and never runs the rejected block" do
    fill_queue
    caller = Thread.current
    ran = false
    expect {
      pool.submit(on_full: :raise, on_rejected: receiver) { ran = true }
    }.to raise_error(Phronomy::BackpressureError) { |error|
      expect(refusals).to eq([[error, caller]])
    }
    @release << true
    pool.shutdown(drain_timeout: 2)
    expect(ran).to be(false)
    expect(refusals.length).to eq(1)
  end

  it "reports a previously closed pool without attempting work" do
    pool.begin_shutdown
    expect {
      pool.submit(on_full: :raise, on_rejected: receiver) { raise "must not start" }
    }.to raise_error(Phronomy::PoolShutdownError) { |error|
      expect(refusals).to eq([[error, Thread.current]])
    }
  end

  it "reports a queue closure racing the pool shutdown flag" do
    pool.instance_variable_get(:@queue).close
    expect {
      pool.submit(on_full: :raise, on_rejected: receiver) { raise "must not start" }
    }.to raise_error(Phronomy::PoolShutdownError) { |error|
      expect(refusals).to eq([[error, Thread.current]])
      expect(error.cause).to be_a(ClosedQueueError)
    }
  end

  it "preserves the original full-queue exception if its evidence receiver raises" do
    fill_queue
    collector = ->(error) {
      refusals << error
      raise IOError, "refusal evidence receiver failed"
    }
    expect {
      pool.submit(on_full: :raise, on_rejected: collector) { raise "must not start" }
    }.to raise_error(Phronomy::BackpressureError) { |error|
      expect(refusals).to eq([error])
    }
  end

  it "preserves the shutdown exception if its evidence receiver raises" do
    pool.begin_shutdown
    expect {
      pool.submit(on_full: :raise, on_rejected: ->(_error) { raise IOError, "collector failed" }) { :unused }
    }.to raise_error(Phronomy::PoolShutdownError)
  end

  it "does not report rejection for an accepted task or its worker error" do
    task = pool.submit(on_full: :raise, on_rejected: receiver) { raise Phronomy::BackpressureError, "worker error" }
    expect { task.wait_result(timeout: 3) }.to raise_error(Phronomy::BackpressureError, "worker error")
    expect(refusals).to be_empty
  end

  it "does not certify a wrapper that enqueues and then raises a rejection-shaped error" do
    ran = Queue.new
    task = nil
    wrapper = lambda do
      task = pool.submit(on_full: :raise, on_rejected: receiver) { ran << true }
      raise Phronomy::BackpressureError, "wrapper failed after admission"
    end
    expect { wrapper.call }.to raise_error(Phronomy::BackpressureError, "wrapper failed after admission")
    task.wait_result(timeout: 3)
    expect(ran.pop(timeout: 3)).to be(true)
    expect(refusals).to be_empty
  end

  it "does not certify an unknown submission error" do
    failure = IOError.new("timer lookup failed")
    allow(pool.instance_variable_get(:@timer_queue_provider)).to receive(:call).and_raise(failure)
    expect {
      pool.submit(timeout: 1, on_full: :raise, on_rejected: receiver) { :unused }
    }.to raise_error { |error| expect(error).to equal(failure) }
    expect(refusals).to be_empty
  end

  it "does not report refusal for a returned task cancelled before entry" do
    token = Phronomy::Concurrency::CancellationToken.new
    token.cancel!
    task = pool.submit(cancellation_token: token, on_full: :raise, on_rejected: receiver) { raise "must not start" }
    expect { task.wait_result(timeout: 3) }.to raise_error(Phronomy::CancellationError)
    expect(refusals).to be_empty
  end

  it "does not infer rejection from a returned task's timeout" do
    task = pool.submit(timeout: 0, on_full: :raise, on_rejected: receiver) { raise "must not start" }
    expect { task.wait_result(timeout: 3) }.to raise_error(Phronomy::TimeoutError)
    expect(refusals).to be_empty
  end

  it "keeps the waiting admission timeout outside the positive refusal protocol" do
    fill_queue
    expect {
      pool.submit(on_full: :timeout, full_timeout: 0, on_rejected: receiver) { :unused }
    }.to raise_error(Phronomy::TimeoutError)
    expect(refusals).to be_empty
  end

  it "forwards positive refusal through the configured Execution binding" do
    fill_queue
    expect {
      Phronomy::Execution.submit(pool: pool, on_full: :raise, on_rejected: receiver) { :unused }
    }.to raise_error(Phronomy::BackpressureError) { |error|
      expect(refusals).to eq([[error, Thread.current]])
    }
  end
end
