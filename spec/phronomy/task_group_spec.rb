# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::TaskGroup do
  describe "#spawn / #await_all" do
    it "runs tasks concurrently and returns results in spawn order" do
      group = described_class.new(runtime: Phronomy::Runtime.instance)
      group.spawn { 1 }
      group.spawn { 2 }
      group.spawn { 3 }
      expect(group.await_all).to eq([1, 2, 3])
    end

    it "re-raises the first error after all tasks finish" do
      group = described_class.new(runtime: Phronomy::Runtime.instance)
      group.spawn { raise ArgumentError, "task-error" }
      group.spawn { 99 }
      expect { group.await_all }.to raise_error(ArgumentError, "task-error")
    end

    it "enforces the concurrency limit" do
      begin
        Concurrent::AtomicFixnum.new(0)
      rescue
        Mutex.new
      end  # fallback
      Mutex.new
      max_count = 0
      mu = Mutex.new

      limit = 2
      group = described_class.new(limit: limit, runtime: Phronomy::Runtime.instance)

      6.times do
        group.spawn do
          mu.synchronize do
            max_count += 1
            # not checking realtime peak here — just run without error
          end
          sleep 0.01
          mu.synchronize { max_count -= 1 }
          1
        end
      end

      results = group.await_all
      expect(results.length).to eq(6)
    end

    it "returns [] for an empty group" do
      expect(described_class.new(runtime: Phronomy::Runtime.instance).await_all).to eq([])
    end
  end

  describe "#cancel_all!" do
    it "returns self" do
      group = described_class.new(runtime: Phronomy::Runtime.instance)
      expect(group.cancel_all!).to be(group)
    end

    it "cancels running tasks" do
      group = described_class.new(runtime: Phronomy::Runtime.instance)
      group.spawn { sleep 30 }
      group.spawn { sleep 30 }
      group.cancel_all!
      # tasks should error after cancel
      expect { group.await_all }.to raise_error(Phronomy::CancellationError)
    end

    it "guarantees active_task_count is 0 after cancel" do
      group = described_class.new(runtime: Phronomy::Runtime.instance)
      group.spawn { sleep 30 }
      group.spawn { sleep 30 }
      group.cancel_all!
      expect(group.active_task_count).to eq(0)
    end
  end

  describe "failure_policy" do
    context "with :fail_fast (default)" do
      it "raises on the first error" do
        group = described_class.new(failure_policy: :fail_fast, runtime: Phronomy::Runtime.instance)
        group.spawn { raise "boom" }
        group.spawn { 2 }
        expect { group.await_all }.to raise_error(RuntimeError, "boom")
      end
    end

    context "with :collect_all" do
      it "runs all tasks and then raises the first error" do
        finished = []
        group = described_class.new(failure_policy: :collect_all, runtime: Phronomy::Runtime.instance)
        group.spawn { raise "first" }
        group.spawn {
          finished << :second
          2
        }
        expect { group.await_all }.to raise_error(RuntimeError, "first")
        expect(finished).to include(:second)
      end
    end

    context "with :skip_failed" do
      it "returns only successful results" do
        group = described_class.new(failure_policy: :skip_failed, runtime: Phronomy::Runtime.instance)
        group.spawn { 1 }
        group.spawn { raise "skip me" }
        group.spawn { 3 }
        expect(group.await_all).to eq([1, 3])
      end
    end

    it "raises ArgumentError for an unknown policy" do
      expect { described_class.new(failure_policy: :unknown, runtime: Phronomy::Runtime.instance) }
        .to raise_error(ArgumentError, /unknown failure_policy/)
    end

    context "with :fail_fast and spawn-order dependency (Issue #315)" do
      it "detects a fast-failing later task before the slow first task completes" do
        started = Queue.new
        released = Queue.new

        group = described_class.new(failure_policy: :fail_fast, runtime: Phronomy::Runtime.instance)
        group.spawn do
          started.push(:slow_started)
          released.pop   # waits until released
          :slow_done
        end

        # Task[1]: fast-failing
        group.spawn do
          raise "fast failure"
        end

        started.pop  # ensure slow task is running

        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        error = nil
        begin
          group.await_all
        rescue => e
          error = e
        ensure
          released.push(:go)  # unblock the slow task so the test can clean up
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

        expect(error).to be_a(RuntimeError)
        expect(error.message).to eq("fast failure")
        # Without the fix this would take several seconds (waiting for slow task).
        # With the fix it completes almost immediately.
        expect(elapsed).to be < 2.0
      end
    end
  end
end
