# frozen_string_literal: true

RSpec.describe Phronomy::Runtime::TimerQueue do
  it "does not create a timer thread" do
    before = Thread.list.length
    timer = described_class.new
    timer.schedule(seconds: 60) { nil }
    expect(Thread.list.length).to eq(before)
  ensure
    timer&.shutdown
  end

  it "fires due callbacks when driven by the caller" do
    now = 0.0
    timer = described_class.new(clock: -> { now })
    fired = []
    timer.schedule(seconds: 5) { fired << :done }

    expect(timer.fire_due).to eq(0)
    now = 5.0
    expect(timer.fire_due).to eq(1)
    expect(fired).to eq([:done])
  ensure
    timer&.shutdown
  end

  it "counts an in-flight callback until it returns, even after it leaves the heap" do
    timer = described_class.new
    entered = Queue.new
    release = Queue.new
    timer.schedule(seconds: 0) do
      entered << true
      release.pop(timeout: 2)
    end
    firing = Thread.new { timer.fire_due }
    expect(entered.pop(timeout: 2)).to be(true)
    expect(timer.pending_count).to eq(0)
    expect(timer.wait_until_idle(Process.clock_gettime(Process::CLOCK_MONOTONIC))).to be(false)
    release << true
    expect(firing.join(2)).not_to be_nil
    expect(timer.wait_until_idle(Process.clock_gettime(Process::CLOCK_MONOTONIC))).to be(true)
  ensure
    release << true
    firing&.join(2)
    timer&.shutdown
  end

  it "accounts for new callbacks scheduled while the current callback is running" do
    timer = described_class.new
    later = -> {}
    timer.schedule(seconds: 0) { timer.schedule(seconds: 60, &later) }
    expect(timer.fire_due).to eq(1)
    expect(timer.wait_until_idle(Process.clock_gettime(Process::CLOCK_MONOTONIC))).to be(false)
    timer.cancel(later)
    expect(timer.wait_until_idle(Process.clock_gettime(Process::CLOCK_MONOTONIC))).to be(true)
  ensure
    timer&.shutdown
  end

  it "releases in-flight accounting after a callback raises" do
    timer = described_class.new
    timer.schedule(seconds: 0) { raise IOError, "timer callback failed" }
    expect(timer.fire_due).to eq(1)
    expect(timer.wait_until_idle(Process.clock_gettime(Process::CLOCK_MONOTONIC))).to be(true)
  ensure
    timer&.shutdown
  end

  it "retains whether the first shutdown discarded an outstanding callback" do
    timer = described_class.new
    timer.schedule(seconds: 60) {}
    expect(timer.shutdown).to equal(timer)
    expect(timer.drained_on_shutdown?).to be(false)
    expect(timer.pending_count).to eq(0)
    timer.shutdown
    expect(timer.drained_on_shutdown?).to be(false)
  end
end
