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
end
