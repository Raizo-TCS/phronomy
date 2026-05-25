# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"

# Group 38: :fiber backend cooperative runtime (Issue #339)
# Factor: fb_subject (7 values, each = 1 test case)
#
# Feasible cases: 7 (TC-001..TC-007)
# Infeasible: none
#
# No LLM required: all cases use DeterministicScheduler (autorun: true)
# and BlockingAdapterPool with pure-Ruby blocks.

RSpec.describe "Group 38: :fiber backend cooperative runtime", :integration do
  # Build a fresh DeterministicScheduler-backed runtime for each example.
  let(:scheduler) { Phronomy::Runtime::DeterministicScheduler.new(autorun: true) }
  let(:runtime) { Phronomy::Runtime.new(scheduler: scheduler) }

  # -------------------------------------------------------------------------
  # TC-001: spawn_await_value — spawn + await returns the task's return value
  # -------------------------------------------------------------------------
  describe "TC-001: spawn_await_value — spawn + await returns the task's return value" do
    it "task.await returns the value produced by the spawned block" do
      task = runtime.spawn(name: "value-task") { 42 }
      expect(task.await).to eq(42)
    end
  end

  # -------------------------------------------------------------------------
  # TC-002: blocking_io_await — PendingOperation#await suspends cooperatively
  # -------------------------------------------------------------------------
  describe "TC-002: blocking_io_await — PendingOperation#await suspends cooperatively" do
    let(:pool) { Phronomy::BlockingAdapterPool.new(pool_size: 2, queue_size: 10) }

    after { pool.shutdown(drain_timeout: 2) }

    it "awaiting Fiber resumes after the worker thread completes the operation" do
      result = nil
      runtime.spawn(name: "io-task") do
        op = pool.submit { :from_worker }
        result = op.await
      end
      expect(result).to eq(:from_worker)
    end

    it "does not block the scheduler while the worker is running" do
      order = []

      # Both children are spawned inside a parent orchestrator so they run
      # within a single run_until_idle loop.  Spawning from the top level in
      # autorun mode would call run_until_idle once per spawn (serialising the
      # tasks), which would defeat the concurrency assertion.
      runtime.spawn(name: "orchestrator") do
        slow_task = runtime.spawn(name: "slow-task") do
          op = pool.submit do
            sleep 0.05
            :slow_result
          end
          order << :before_await
          op.await
          order << :after_await
        end

        fast_task = runtime.spawn(name: "fast-task") do
          order << :fast_ran
        end

        slow_task.await
        fast_task.await
      end

      # fast-task must run while slow-task is suspended in op.await
      expect(order).to include(:fast_ran)
      expect(order.index(:fast_ran)).to be < order.index(:after_await)
      expect(order.first).to eq(:before_await)
    end
  end

  # -------------------------------------------------------------------------
  # TC-003: async_queue_pop — AsyncQueue#pop suspends cooperatively
  # -------------------------------------------------------------------------
  describe "TC-003: async_queue_pop — AsyncQueue#pop suspends cooperatively" do
    it "consumer task resumes when producer pushes a value" do
      queue = Phronomy::AsyncQueue.new
      received = nil

      runtime.spawn(name: "consumer") do
        received = queue.pop
      end

      runtime.spawn(name: "producer") do
        queue.push(:hello)
      end

      expect(received).to eq(:hello)
    end
  end

  # -------------------------------------------------------------------------
  # TC-004: spawn_child — child task completes before parent resumes
  # -------------------------------------------------------------------------
  describe "TC-004: spawn_child — child task completes before parent resumes" do
    it "parent task awaits the child task's result cooperatively" do
      parent_result = nil

      runtime.spawn(name: "parent") do
        child = runtime.spawn(name: "child") { :child_value }
        parent_result = child.await
      end

      expect(parent_result).to eq(:child_value)
    end
  end

  # -------------------------------------------------------------------------
  # TC-005: error_propagation — exception from spawned block propagates through await
  # -------------------------------------------------------------------------
  describe "TC-005: error_propagation — exception propagates through task.await" do
    it "raises the original exception class and message in the awaiting fiber" do
      raised = nil

      runtime.spawn(name: "catcher") do
        child = runtime.spawn(name: "raiser") { raise ArgumentError, "fiber error" }
        begin
          child.await
        rescue ArgumentError => e
          raised = e
        end
      end

      expect(raised).to be_a(ArgumentError)
      expect(raised.message).to eq("fiber error")
    end
  end

  # -------------------------------------------------------------------------
  # TC-006: cancellation — task.cancel! transitions the task to :cancelled
  # -------------------------------------------------------------------------
  describe "TC-006: cancellation — task.cancel! transitions the task to :cancelled" do
    it "the task transitions to :cancelled when cancel! is called" do
      cancelled_status = nil

      runtime.spawn(name: "orchestrator") do
        child = runtime.spawn(name: "cancellable") do
          # Block on an inner spawn to create a cooperative yield point;
          # the task is scheduled but not yet dispatched when cancel! fires.
          inner = runtime.spawn(name: "inner") { :inner_value }
          inner.await
          :should_not_reach
        end

        # cancel! transitions the task to :cancelled immediately (via
        # Task#transition!) before the scheduler dispatches the child fiber.
        child.cancel!
        cancelled_status = child.status
      end

      expect(cancelled_status).to eq(:cancelled)
    end
  end

  # -------------------------------------------------------------------------
  # TC-007: timer_real_clock — SchedulerTimerAdapter fires after real deadline
  # -------------------------------------------------------------------------
  describe "TC-007: timer_real_clock — real-clock timer fires automatically via run_until_idle" do
    let(:timer_adapter) { Phronomy::Runtime::SchedulerTimerAdapter.new(scheduler) }

    it "fires the callback after the wall-clock deadline has passed (Issue #337)" do
      fired_at = nil
      scheduled_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      timer_adapter.schedule(seconds: 0.05) do
        fired_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Spawn a no-op task so run_until_idle is triggered via autorun.
      # The scheduler sleeps until the 50ms deadline, fires the timer, then returns.
      runtime.spawn(name: "noop") { nil }

      expect(fired_at).not_to be_nil
      expect(fired_at - scheduled_at).to be >= 0.04
    end
  end
end
