# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Runtime::SchedulerTimerAdapter do
  subject(:adapter) { described_class.new(scheduler) }

  let(:scheduler) { Phronomy::Runtime::DeterministicScheduler.new(autorun: true) }

  describe "#schedule / callback firing (Issue #331)" do
    it "fires the callback via fire_real_timers when the deadline has passed" do
      fired = false
      adapter.schedule(seconds: 0) { fired = true }
      scheduler.fire_real_timers
      scheduler.run_until_idle
      expect(fired).to be(true)
    end

    it "does not fire the callback before the deadline" do
      fired = false
      adapter.schedule(seconds: 9999) { fired = true }
      scheduler.fire_real_timers
      expect(fired).to be(false)
    end

    it "fires the callback automatically via autorun run_until_idle when deadline has passed" do
      fired = false
      adapter.schedule(seconds: 0) { fired = true }
      # spawn a no-op task to trigger run_until_idle which fires real timers
      Phronomy::Runtime.new(scheduler: scheduler).spawn { nil }
      expect(fired).to be(true)
    end

    it "fires a future-deadline callback automatically via run_until_idle (Issue #337)" do
      fired_at = nil
      scheduled_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      adapter.schedule(seconds: 0.05) { fired_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      # spawn a no-op task so run_until_idle is driven; autorun will sleep until
      # the 50ms deadline, fire the timer, then return
      Phronomy::Runtime.new(scheduler: scheduler).spawn { nil }
      expect(fired_at).not_to be_nil
      expect(fired_at - scheduled_at).to be >= 0.04
    end
  end

  describe "#pending_count" do
    it "returns the number of un-fired real-clock callbacks" do
      adapter.schedule(seconds: 9999) { nil }
      adapter.schedule(seconds: 9999) { nil }
      expect(adapter.pending_count).to eq(2)
    end

    it "decrements after fire_real_timers fires due callbacks" do
      adapter.schedule(seconds: 0) { nil }
      expect(adapter.pending_count).to eq(1)
      scheduler.fire_real_timers
      scheduler.run_until_idle
      expect(adapter.pending_count).to eq(0)
    end
  end

  describe "#shutdown" do
    it "raises PoolShutdownError after shutdown" do
      adapter.shutdown
      expect { adapter.schedule(seconds: 1) { nil } }
        .to raise_error(Phronomy::PoolShutdownError)
    end

    it "is a no-op regarding background threads (no thread to stop)" do
      thread_count_before = Thread.list.count
      adapter.shutdown
      expect(Thread.list.count).to eq(thread_count_before)
    end
  end

  describe "Runtime#timer_queue integration (Issue #331)" do
    around do |ex|
      Phronomy.reset_configuration!
      original_instance = Phronomy::Runtime.instance_variable_get(:@instance)
      Phronomy::Runtime.instance_variable_set(:@instance, nil)
      ex.run
    ensure
      Phronomy.reset_configuration!
      Phronomy::Runtime.instance_variable_set(:@instance, original_instance)
    end

    it "returns SchedulerTimerAdapter when scheduler is DeterministicScheduler" do
      runtime = Phronomy::Runtime.new(scheduler: scheduler)
      expect(runtime.timer_queue).to be_a(described_class)
    end

    it "returns TimerQueue when scheduler is ThreadScheduler" do
      thread_runtime = Phronomy::Runtime.new(scheduler: Phronomy::Runtime::ThreadScheduler.new)
      tq = thread_runtime.timer_queue
      expect(tq).to be_a(Phronomy::Runtime::TimerQueue)
    ensure
      thread_runtime.timer_queue.shutdown
      thread_runtime.shutdown
    end

    it "does not spawn a background thread for :fiber backend (Issue #331)" do
      Phronomy.configure { |c| c.runtime_backend = :fiber }
      # SchedulerTimerAdapter has no background thread — verified by checking
      # that the returned object is not a TimerQueue (which owns a thread).
      tq = Phronomy::Runtime.instance.timer_queue
      expect(tq).to be_a(described_class)
      expect(tq).not_to be_a(Phronomy::Runtime::TimerQueue)
    end
  end
end
