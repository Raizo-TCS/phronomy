# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Testing::FakeClock do
  subject(:clock) { described_class.new }

  it "starts at time 0" do
    expect(clock.now).to eq(0.0)
  end

  it "fires callbacks when advanced past their scheduled time" do
    fired = []
    clock.at(2.0) { fired << :a }
    clock.at(3.5) { fired << :b }

    clock.advance(2.5)
    expect(fired).to eq([:a])

    clock.advance(1.5)
    expect(fired).to eq([:a, :b])
  end

  it "schedules relative to current time" do
    fired = []
    clock.advance(5.0)
    clock.schedule(seconds: 2.0) { fired << :scheduled }
    clock.advance(2.0)
    expect(fired).to eq([:scheduled])
  end

  it "returns nil for next_timer_at when no callbacks are pending" do
    expect(clock.next_timer_at).to be_nil
  end

  it "returns the earliest pending callback time" do
    clock.at(10.0) {}
    clock.at(3.0) {}
    expect(clock.next_timer_at).to eq(3.0)
  end

  it "advance_to_next_timer advances exactly to the next scheduled time" do
    clock.at(4.0) {}
    clock.advance_to_next_timer
    expect(clock.now).to eq(4.0)
  end

  it "advance_to_next_timer raises when no timers are pending" do
    expect { clock.advance_to_next_timer }.to raise_error(RuntimeError, /No pending timers/)
  end
end
