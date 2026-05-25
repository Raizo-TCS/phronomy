# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Runtime::DeterministicScheduler, :issue_320 do
  subject(:scheduler) { described_class.new }

  let(:runtime) { Phronomy::Runtime.new(scheduler: scheduler) }

  # ---------------------------------------------------------------------------
  # Initialization
  # ---------------------------------------------------------------------------
  describe "initialization" do
    it "starts with virtual_time == 0.0" do
      expect(scheduler.virtual_time).to eq(0.0)
    end

    it "starts idle" do
      expect(scheduler).to be_idle
    end
  end

  # ---------------------------------------------------------------------------
  # spawn / tick
  # ---------------------------------------------------------------------------
  describe "#spawn + #tick" do
    it "does not run the task before tick is called" do
      executed = false
      runtime.spawn { executed = true }
      expect(executed).to be false
    end

    it "runs the task after tick" do
      executed = false
      runtime.spawn { executed = true }
      scheduler.run_until_idle
      expect(executed).to be true
    end

    it "runs two independent tasks interleaved via Fiber.yield" do
      log = []
      runtime.spawn do
        log << :a1
        Fiber.yield
        log << :a2
      end
      runtime.spawn do
        log << :b1
        Fiber.yield
        log << :b2
      end

      # Each tick advances one task by one step.
      scheduler.tick  # a1
      scheduler.tick  # b1
      scheduler.tick  # a2
      scheduler.tick  # b2

      expect(log).to eq(%i[a1 b1 a2 b2])
    end

    it "returns the Task from spawn" do
      task = runtime.spawn { 42 }
      scheduler.run_until_idle
      expect(task.status).to eq(:completed)
    end

    it "raises correct value from await after run_until_idle" do
      task = runtime.spawn { 99 }
      scheduler.run_until_idle
      expect(task.await).to eq(99)
    end
  end

  # ---------------------------------------------------------------------------
  # run_until_idle
  # ---------------------------------------------------------------------------
  describe "#run_until_idle" do
    it "drains all ready tasks" do
      results = []
      3.times { |i| runtime.spawn { results << i } }
      scheduler.run_until_idle
      expect(results).to contain_exactly(0, 1, 2)
    end

    it "drains transitively spawned tasks" do
      results = []
      runtime.spawn do
        results << :outer
        # spawn from within a running task
        runtime.spawn { results << :inner }
      end
      scheduler.run_until_idle
      expect(results).to contain_exactly(:outer, :inner)
    end
  end

  # ---------------------------------------------------------------------------
  # Virtual clock + timers
  # ---------------------------------------------------------------------------
  describe "#advance + #schedule_after" do
    it "does not fire timers before advance" do
      fired = false
      scheduler.schedule_after(1.0) { fired = true }
      scheduler.run_until_idle
      expect(fired).to be false
    end

    it "fires a timer after advance past its due time" do
      fired = false
      scheduler.schedule_after(1.0) { fired = true }
      scheduler.advance(1.0)
      scheduler.run_until_idle
      expect(fired).to be true
    end

    it "advances virtual_time" do
      scheduler.advance(5.0)
      expect(scheduler.virtual_time).to eq(5.0)
    end

    it "fires timers in chronological order" do
      order = []
      scheduler.schedule_after(2.0) { order << :two }
      scheduler.schedule_after(1.0) { order << :one }
      scheduler.advance(3.0)
      scheduler.run_until_idle
      expect(order).to eq(%i[one two])
    end

    it "does not fire a timer scheduled after the advance point" do
      fired = false
      scheduler.schedule_after(2.0) { fired = true }
      scheduler.advance(1.0)
      scheduler.run_until_idle
      expect(fired).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # schedule_at
  # ---------------------------------------------------------------------------
  describe "#schedule_at" do
    it "fires at the specified absolute virtual time" do
      fired = false
      scheduler.schedule_at(3.0) { fired = true }
      scheduler.advance(3.0)
      scheduler.run_until_idle
      expect(fired).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # ready_count / pending_timers
  # ---------------------------------------------------------------------------
  describe "introspection" do
    it "#ready_count returns the number of queued steps" do
      runtime.spawn { nil }
      runtime.spawn { nil }
      expect(scheduler.ready_count).to eq(2)
    end

    it "#pending_timers returns unsatisfied timer entries" do
      scheduler.schedule_after(1.0) {}
      scheduler.schedule_after(2.0) {}
      expect(scheduler.pending_timers.size).to eq(2)
      scheduler.advance(1.0)
      expect(scheduler.pending_timers.size).to eq(1)
    end
  end

  # ---------------------------------------------------------------------------
  # Cancellation
  # ---------------------------------------------------------------------------
  describe "cancellation" do
    it "can cancel a task that has not yet started" do
      task = runtime.spawn { raise "should not run" }
      task.cancel!
      scheduler.run_until_idle
      expect(task.status).to eq(:cancelled)
    end

    it "can cancel a suspended task" do
      reached_after_yield = false
      task = runtime.spawn do
        Fiber.yield  # suspend here
        reached_after_yield = true
      end

      scheduler.tick      # run until first Fiber.yield
      task.cancel!
      scheduler.run_until_idle

      expect(task.status).to eq(:cancelled)
      expect(reached_after_yield).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # Task#await cooperative suspension
  # ---------------------------------------------------------------------------
  describe "cooperative await" do
    it "suspends the awaiting fiber and resumes it on completion" do
      log = []
      inner_task = nil

      runtime.spawn do
        log << :outer_before
        inner_task = runtime.spawn { log << :inner }
        # This should cooperatively suspend the outer fiber until inner completes.
        inner_task.await
        log << :outer_after
      end

      scheduler.run_until_idle
      expect(log).to eq(%i[outer_before inner outer_after])
    end
  end

  # ---------------------------------------------------------------------------
  # Scheduler signal API (Issue #321/#330)
  # ---------------------------------------------------------------------------
  describe "signal API (cooperative synchronization)" do
    describe "#new_signal / #wait_for_signal / #raise_signal" do
      it "suspends a fiber waiting on a signal and resumes it on raise_signal" do
        log = []
        signal = scheduler.new_signal

        runtime.spawn do
          log << :before_wait
          scheduler.wait_for_signal(signal)
          log << :after_wait
        end

        runtime.spawn do
          log << :notifier
          scheduler.raise_signal(signal)
        end

        scheduler.run_until_idle
        expect(log).to eq(%i[before_wait notifier after_wait])
      end

      it "#raise_signal_all wakes up multiple waiters" do
        log = []
        signal = scheduler.new_signal

        2.times { |i|
          runtime.spawn {
            scheduler.wait_for_signal(signal)
            log << i
          }
        }
        runtime.spawn { scheduler.raise_signal_all(signal) }

        scheduler.run_until_idle
        expect(log).to contain_exactly(0, 1)
      end
    end

    describe "ConcurrencyGate (cooperative, on_full: :wait)" do
      it "queues tasks cooperatively when the gate is at capacity" do
        gate = Phronomy::ConcurrencyGate.new(max_concurrent: 1, name: :test)
        log = []

        # Both tasks try to acquire the gate; only one can hold it at a time.
        runtime.spawn do
          gate.acquire(on_full: :wait) { log << :task_a }
        end
        runtime.spawn do
          gate.acquire(on_full: :wait) { log << :task_b }
        end

        scheduler.run_until_idle
        expect(log).to contain_exactly(:task_a, :task_b)
      end
    end

    describe "TaskGroup (cooperative concurrency limit)" do
      it "honours the limit cooperatively without blocking the thread" do
        group = Phronomy::TaskGroup.new(limit: 1, runtime: runtime)
        log = []

        # Spawn 2 tasks into a limit-1 group inside a controlling fiber.
        runtime.spawn do
          group.spawn {
            log << :task_a
            Fiber.yield
          }
          group.spawn { log << :task_b }
          group.await_all
        end

        scheduler.run_until_idle
        expect(log).to contain_exactly(:task_a, :task_b)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Error propagation
  # ---------------------------------------------------------------------------
  describe "error propagation" do
    it "marks the task as failed" do
      task = runtime.spawn { raise ArgumentError, "boom" }
      scheduler.run_until_idle
      expect(task.status).to eq(:failed)
    end

    it "re-raises the error on await" do
      task = runtime.spawn { raise ArgumentError, "boom" }
      scheduler.run_until_idle
      expect { task.await }.to raise_error(ArgumentError, "boom")
    end
  end
end
