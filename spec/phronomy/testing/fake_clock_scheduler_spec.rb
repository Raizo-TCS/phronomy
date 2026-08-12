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
end
