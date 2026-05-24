# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Runtime do
  describe ".instance" do
    it "returns the same object on repeated calls" do
      expect(described_class.instance).to be(described_class.instance)
    end

    it "returns a Runtime" do
      expect(described_class.instance).to be_a(described_class)
    end
  end

  describe ".instance=" do
    after do
      # Reset to a fresh instance after the test
      described_class.instance_variable_set(:@instance, nil)
    end

    it "replaces the shared instance" do
      custom = described_class.new
      described_class.instance = custom
      expect(described_class.instance).to be(custom)
    end
  end

  describe "#task_group" do
    it "returns a TaskGroup" do
      group = described_class.instance.task_group
      expect(group).to be_a(Phronomy::TaskGroup)
    end

    it "passes the limit to the TaskGroup" do
      group = described_class.instance.task_group(limit: 3)
      expect(group.instance_variable_get(:@limit)).to eq(3)
    end
  end

  describe "#spawn" do
    it "returns a Task" do
      task = described_class.instance.spawn { 7 }
      expect(task).to be_a(Phronomy::Task)
      expect(task.await).to eq(7)
    end

    it "accepts an optional name" do
      task = described_class.instance.spawn(name: "rt-task") { :ok }
      expect(task.name).to eq("rt-task")
      task.await
    end
  end

  # ---------------------------------------------------------------------------
  # Scheduler injection (#282 acceptance criteria)
  # ---------------------------------------------------------------------------

  describe "scheduler injection" do
    subject(:runtime) { described_class.new(scheduler: described_class::FakeScheduler.new) }

    it "accepts a custom scheduler at construction time" do
      expect(runtime).to be_a(described_class)
    end

    it "spawns tasks through the injected scheduler" do
      task = runtime.spawn { 99 }
      expect(task).to be_a(Phronomy::Task)
      expect(task.await).to eq(99)
    end
  end

  # ---------------------------------------------------------------------------
  # FakeScheduler: no thread increase (#282 acceptance criteria)
  # ---------------------------------------------------------------------------

  describe described_class::FakeScheduler do
    subject(:runtime) { Phronomy::Runtime.new(scheduler: Phronomy::Runtime::FakeScheduler.new) }

    it "does not increase Thread count when spawning a task" do
      before = Thread.list.length
      runtime.spawn { :noop }
      after = Thread.list.length
      expect(after).to eq(before)
    end

    it "executes the block synchronously before spawn returns" do
      results = []
      runtime.spawn { results << :done }
      expect(results).to eq([:done])
    end

    it "returns a completed task immediately" do
      task = runtime.spawn { 42 }
      expect(task.status).to eq(:completed)
    end

    it "does not leak completed tasks in the registry (Issue #314)" do
      runtime = Phronomy::Runtime.new(scheduler: Phronomy::Runtime::FakeScheduler.new)

      # FakeScheduler runs synchronously — task is done before spawn returns.
      # Before the fix, @tasks << task was added AFTER ensure fired, so the
      # task was never removed and the registry kept growing.
      3.times { runtime.spawn { :result } }

      tasks = runtime.instance_variable_get(:@tasks)
      # All tasks completed synchronously; registry must be empty.
      expect(tasks).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # #shutdown (#282 acceptance criteria)
  # ---------------------------------------------------------------------------

  describe "#shutdown" do
    it "waits for all registered tasks to complete" do
      runtime = described_class.new
      latch = Queue.new
      task = runtime.spawn {
        latch.pop
        :done
      }

      thread = Thread.new { runtime.shutdown }
      latch.push(:go)
      thread.join(3)

      expect(task.status).to eq(:completed)
    end

    it "shuts down the blocking adapter pool when it was started" do
      runtime = described_class.new
      pool = runtime.blocking_io
      runtime.shutdown
      expect(pool.instance_variable_get(:@shutdown)).to be true
    end

    it "does not raise when called with no tasks and no pool" do
      runtime = described_class.new
      expect { runtime.shutdown }.not_to raise_error
    end
  end

  # ---------------------------------------------------------------------------
  # Task auto-deregistration (Issue #289)
  # ---------------------------------------------------------------------------

  describe "#spawn task registry auto-deregistration (Issue #289)" do
    subject(:runtime) { described_class.new }

    it "removes a completed task from the registry" do
      task = runtime.spawn { :done }
      task.await
      tasks = runtime.instance_variable_get(:@tasks)
      expect(tasks).not_to include(task)
    end

    it "removes a failed task from the registry" do
      task = runtime.spawn { raise ArgumentError, "boom" }
      begin
        task.await
      rescue
        nil
      end
      tasks = runtime.instance_variable_get(:@tasks)
      expect(tasks).not_to include(task)
    end

    it "does not accumulate tasks across many spawns" do
      20.times { runtime.spawn { :done }.await }
      tasks = runtime.instance_variable_get(:@tasks)
      expect(tasks.length).to eq(0)
    end

    it "still drains in-flight tasks on shutdown" do
      latch = Queue.new
      task = runtime.spawn {
        latch.pop
        :done
      }
      shutdown_thread = Thread.new { runtime.shutdown }
      latch.push(:go)
      shutdown_thread.join(3)
      expect(task.status).to eq(:completed)
    end
  end

  # ---------------------------------------------------------------------------
  # Runtime.in_scheduler_context? (Issue #312)
  # ---------------------------------------------------------------------------

  describe ".in_scheduler_context?" do
    it "returns false when called outside any task" do
      expect(described_class.in_scheduler_context?).to be(false)
    end

    it "returns true when called from inside a spawned task" do
      result = nil
      runtime = described_class.new(scheduler: described_class::FakeScheduler.new)
      runtime.spawn { result = described_class.in_scheduler_context? }
      expect(result).to be(true)
    end
  end

  # ---------------------------------------------------------------------------
  # Runtime.instance respects runtime_backend (Issue #313)
  # ---------------------------------------------------------------------------

  describe ".instance respects runtime_backend configuration" do
    around do |ex|
      Phronomy.reset_configuration!
      original_instance = described_class.instance_variable_get(:@instance)
      described_class.instance_variable_set(:@instance, nil)
      ex.run
    ensure
      Phronomy.reset_configuration!
      described_class.instance_variable_set(:@instance, original_instance)
    end

    it "uses ThreadScheduler by default (:thread backend)" do
      Phronomy.configure { |c| c.runtime_backend = :thread }
      expect(described_class.instance.scheduler).to be_a(Phronomy::Runtime::ThreadScheduler)
    end

    it "uses FakeScheduler for :deterministic backend" do
      Phronomy.configure { |c| c.runtime_backend = :deterministic }
      expect(described_class.instance.scheduler).to be_a(Phronomy::Runtime::FakeScheduler)
    end
  end
end
