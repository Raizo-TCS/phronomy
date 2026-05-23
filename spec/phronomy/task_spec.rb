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
      task = described_class.spawn { barrier.lock; 1 }
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
      task.instance_variable_get(:@thread).join rescue nil
    end

    it "causes await to raise CancellationError" do
      task = described_class.spawn { sleep 10 }
      task.cancel!
      expect { task.await }.to raise_error(Phronomy::CancellationError)
    end
  end
end
