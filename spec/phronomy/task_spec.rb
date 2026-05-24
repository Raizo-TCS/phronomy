# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Task do
  describe ".spawn" do
    it "returns a Task instance" do
      task = described_class.spawn { 42 }
      expect(task).to be_a(described_class)
      task.await
    end

    it "accepts an optional name" do
      task = described_class.spawn(name: "my-task") { 1 }
      expect(task.name).to eq("my-task")
      task.await
    end
  end

  describe "#await" do
    it "returns the block value" do
      task = described_class.spawn { 2 + 2 }
      expect(task.await).to eq(4)
    end

    it "re-raises errors from the block" do
      task = described_class.spawn { raise ArgumentError, "boom" }
      expect { task.await }.to raise_error(ArgumentError, "boom")
    end

    it "is idempotent — may be called multiple times" do
      task = described_class.spawn { 99 }
      expect(task.await).to eq(99)
      expect(task.await).to eq(99)
    end
  end

  describe "#done?" do
    it "returns false before the block completes" do
      barrier = Mutex.new
      barrier.lock
      task = described_class.spawn {
        barrier.lock
        1
      }
      expect(task.done?).to be(false)
      barrier.unlock
      task.await
    end

    it "returns true after the block completes" do
      task = described_class.spawn { 1 }
      task.await
      expect(task.done?).to be(true)
    end
  end

  describe "#cancel!" do
    it "returns self" do
      task = described_class.spawn { sleep 10 }
      expect(task.cancel!).to be(task)
      begin
        task.join
      rescue
        nil
      end
    end

    it "causes await to raise CancellationError" do
      task = described_class.spawn { sleep 10 }
      task.cancel!
      expect { task.await }.to raise_error(Phronomy::CancellationError)
    end
  end

  describe "#status" do
    it "transitions from pending to running to completed" do
      started = Queue.new
      task = described_class.spawn do
        started.push(:go)
        sleep 0.01
        :done
      end
      started.pop
      expect(task.status).to eq(:running)
      task.await
      expect(task.status).to eq(:completed)
    end

    it "is :failed when the block raises" do
      task = described_class.spawn { raise "boom" }
      begin
        task.await
      rescue
        nil
      end
      expect(task.status).to eq(:failed)
    end

    it "is :cancelled when cancelled" do
      task = described_class.spawn { sleep 10 }
      task.cancel!
      begin
        task.join
      rescue
        nil
      end
      expect(task.status).to eq(:cancelled)
    end
  end

  describe "#parent and child cancellation propagation" do
    it "returns nil parent for top-level tasks spawned outside any task context" do
      task = described_class.spawn(parent: nil) { 1 }
      expect(task.parent).to be_nil
      task.await
    end

    it "propagates cancel! from parent to child" do
      child_task = nil
      parent = described_class.spawn(parent: nil) do
        child_task = described_class.spawn(parent: described_class.current) { sleep 10 }
        sleep 10
      end
      sleep 0.02 until child_task
      parent.cancel!
      begin
        parent.join
      rescue
        nil
      end
      begin
        child_task.join
      rescue
        nil
      end
      expect(child_task.status).to eq(:cancelled)
    end
  end

  describe ".current" do
    it "returns nil outside a task" do
      expect(described_class.current).to be_nil
    end

    it "returns the running Task from within its own block" do
      captured = nil
      task = described_class.spawn { captured = described_class.current }
      task.await
      expect(captured).to be(task)
    end
  end

  describe ".checkpoint!" do
    it "is a no-op outside a task context" do
      expect { described_class.checkpoint! }.not_to raise_error
    end

    it "raises CancellationError when the current task status is :cancelled" do
      reached_checkpoint = Queue.new
      error_captured = nil
      task = described_class.spawn(parent: nil) do
        described_class.current.transition!(:cancelled)
        begin
          described_class.checkpoint!
        rescue Phronomy::CancellationError => e
          error_captured = e
          reached_checkpoint.push(:done)
        end
      end
      begin
        task.await
      rescue
        nil
      end
      reached_checkpoint.pop
      expect(error_captured).to be_a(Phronomy::CancellationError)
    end
  end

  describe ".default_backend_class" do
    it "defaults to ThreadBackend" do
      expect(described_class.default_backend_class).to eq(Phronomy::Task::ThreadBackend)
    end

    it "can be overridden and restored" do
      original = described_class.default_backend_class
      fake = Class.new(Phronomy::Task::Backend)
      described_class.default_backend_class = fake
      expect(described_class.default_backend_class).to eq(fake)
    ensure
      described_class.default_backend_class = original
    end
  end
end
