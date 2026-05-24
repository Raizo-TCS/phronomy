# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Runtime::TimerQueue do
  subject(:queue) { described_class.new(clock: -> { fake_clock.now }) }

  let(:fake_clock) { Phronomy::Testing::FakeClock.new }

  after { queue.shutdown }

  describe "#schedule / callback firing" do
    it "fires the callback after the specified delay" do
      fired = false
      # Use wall-clock timer for a short delay so no FakeClock needed.
      real_queue = described_class.new
      real_queue.schedule(seconds: 0.05) { fired = true }
      sleep 0.12
      expect(fired).to be(true)
      real_queue.shutdown
    end

    it "fires callbacks in deadline order" do
      order = []
      real_queue = described_class.new
      real_queue.schedule(seconds: 0.02) { order << :a }
      real_queue.schedule(seconds: 0.05) { order << :b }
      sleep 0.12
      real_queue.shutdown
      expect(order).to eq(%i[a b])
    end

    it "does not fire the callback before the delay" do
      fired = false
      real_queue = described_class.new
      real_queue.schedule(seconds: 10) { fired = true }
      sleep 0.02
      expect(fired).to be(false)
      real_queue.shutdown
    end
  end

  describe "#pending_count" do
    it "reflects the number of un-fired callbacks" do
      # Use a far-future schedule so they never fire during the test.
      queue.schedule(seconds: 9999) { nil }
      queue.schedule(seconds: 9999) { nil }
      expect(queue.pending_count).to eq(2)
    end

    it "decrements after a callback fires" do
      real_queue = described_class.new
      real_queue.schedule(seconds: 0.03) { nil }
      expect(real_queue.pending_count).to eq(1)
      sleep 0.08
      expect(real_queue.pending_count).to eq(0)
      real_queue.shutdown
    end
  end

  describe "#shutdown" do
    it "returns self" do
      tq = described_class.new
      expect(tq.shutdown).to be(tq)
    end

    it "stops the background thread" do
      tq = described_class.new
      thread = tq.instance_variable_get(:@thread)
      tq.shutdown
      expect(thread.alive?).to be(false)
    end
  end

  describe "integration with Deadline and CancellationToken" do
    it "cancels the token when the deadline fires via timer queue" do
      token = Phronomy::CancellationToken.new
      fake_tq = Phronomy::Testing::FakeClock.new
      Phronomy::Deadline.in(5).attach_to(token, timer_queue: fake_tq)
      expect(token.cancelled?).to be(false)
      fake_tq.advance(6)
      expect(token.cancelled?).to be(true)
    end

    it "does not cancel the token before the deadline" do
      token = Phronomy::CancellationToken.new
      fake_tq = Phronomy::Testing::FakeClock.new
      Phronomy::Deadline.in(5).attach_to(token, timer_queue: fake_tq)
      fake_tq.advance(4)
      expect(token.cancelled?).to be(false)
    end
  end

  describe "regression: Issue #318 — callback exception and schedule-after-shutdown safety" do
    it "does not kill the timer thread when a callback raises" do
      real_queue = described_class.new
      fired_after = false

      real_queue.schedule(seconds: 0.01) { raise "boom" }
      real_queue.schedule(seconds: 0.05) { fired_after = true }
      sleep 0.12

      expect(fired_after).to be(true), "timer thread died after callback exception"
      real_queue.shutdown
    end

    it "raises SchedulerShutdownError (or equivalent) when schedule is called after shutdown" do
      tq = described_class.new
      tq.shutdown
      expect { tq.schedule(seconds: 1) { nil } }.to raise_error(Phronomy::Error)
    end
  end

  describe "acceptance criterion: 1000 Deadline instances do not add 1000 Threads" do
    it "creates at most 1 extra thread for all deadlines" do
      runtime = Phronomy::Runtime.new
      before_count = Thread.list.size

      tokens = Array.new(1000) { Phronomy::CancellationToken.new }
      tokens.each { |t| Phronomy::Deadline.in(60).attach_to(t, timer_queue: runtime.timer_queue) }

      after_count = Thread.list.size
      runtime.shutdown

      # At most 1 extra thread for the timer queue itself.
      expect(after_count - before_count).to be <= 1
    end
  end
end
