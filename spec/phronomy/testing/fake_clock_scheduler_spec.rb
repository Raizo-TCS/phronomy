# frozen_string_literal: true

RSpec.describe "FakeClock and FakeScheduler (Issue #273)" do
  describe Phronomy::Testing::FakeClock do
    subject(:clock) { described_class.new }

    it "starts at t=0" do
      expect(clock.now).to eq(0.0)
    end

    it "advances time" do
      clock.advance(5)
      expect(clock.now).to eq(5.0)
    end

    it "accumulates multiple advances" do
      clock.advance(3)
      clock.advance(2)
      expect(clock.now).to eq(5.0)
    end

    it "fires a callback when its deadline is reached" do
      fired = false
      clock.at(10) { fired = true }
      clock.advance(10)
      expect(fired).to be(true)
    end

    it "does not fire a callback before its deadline" do
      fired = false
      clock.at(10) { fired = true }
      clock.advance(9)
      expect(fired).to be(false)
    end

    it "fires callbacks in deadline order" do
      order = []
      clock.at(5) { order << :b }
      clock.at(3) { order << :a }
      clock.advance(10)
      expect(order).to eq([:a, :b])
    end

    it "reports pending_callbacks count" do
      clock.at(1) { nil }
      clock.at(2) { nil }
      expect(clock.pending_callbacks).to eq(2)
      clock.advance(1.5)
      expect(clock.pending_callbacks).to eq(1)
    end
  end

  describe Phronomy::Testing::FakeScheduler do
    subject(:scheduler) { described_class.new }

    it "starts with empty queue" do
      expect(scheduler.queue_depth).to eq(0)
      expect(scheduler.idle?).to be(true)
    end

    it "post increases queue depth" do
      scheduler.post(:x)
      expect(scheduler.queue_depth).to eq(1)
    end

    it "tick dispatches the next event" do
      scheduler.post(:a)
      result = scheduler.tick
      expect(result).to eq(:a)
      expect(scheduler.dispatched).to eq([:a])
    end

    it "tick returns nil when queue is empty" do
      expect(scheduler.tick).to be_nil
    end

    it "tick_until_idle drains the queue" do
      3.times { |i| scheduler.post(i) }
      count = scheduler.tick_until_idle
      expect(count).to eq(3)
      expect(scheduler.idle?).to be(true)
      expect(scheduler.dispatched).to eq([0, 1, 2])
    end

    it "calls registered handler on tick" do
      received = []
      scheduler.on(Symbol) { |e| received << e }
      scheduler.post(:hello)
      scheduler.tick
      expect(received).to eq([:hello])
    end

    it "calls :any handler for any event type" do
      received = []
      scheduler.on(:any) { |e| received << e }
      scheduler.post(:sym)
      scheduler.post(42)
      scheduler.tick_until_idle
      expect(received).to eq([:sym, 42])
    end
  end
end
