# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::AsyncQueue do
  describe "#push / #pop" do
    it "transfers values FIFO" do
      q = described_class.new
      q.push(1)
      q.push(2)
      expect(q.pop).to eq(1)
      expect(q.pop).to eq(2)
    end

    it "blocks pop until an item is available" do
      q = described_class.new
      result = nil
      thread = Thread.new { result = q.pop }
      sleep 0.02
      expect(result).to be_nil
      q.push(:hello)
      thread.join(1)
      expect(result).to eq(:hello)
    end
  end

  describe "#size / #empty?" do
    it "tracks queue depth" do
      q = described_class.new
      expect(q.empty?).to be(true)
      q.push(:a)
      expect(q.size).to eq(1)
      expect(q.empty?).to be(false)
      q.pop
      expect(q.empty?).to be(true)
    end
  end

  describe "max_size" do
    it "blocks push when the queue is full" do
      q = described_class.new(max_size: 1)
      q.push(:first)
      blocked = false
      t = Thread.new do
        blocked = true
        q.push(:second)
      end
      sleep 0.02
      expect(blocked).to be(true)
      q.pop
      t.join(1)
    end
  end

  describe "#close" do
    it "returns self" do
      expect(described_class.new.close).to be_a(described_class)
    end
  end

  # Issue #284 — EventLoop and CancellationScope must not reference Thread::Queue
  # directly; all queue usage must go through Phronomy::AsyncQueue so the backing
  # primitive can be swapped without touching call sites.
  describe "pop with timeout (Issue #284)", :issue_284 do
    it "returns nil when the queue is empty and the timeout expires" do
      q = described_class.new
      result = q.pop(timeout: 0.05)
      expect(result).to be_nil
    end

    it "returns the item immediately when one is already present" do
      q = described_class.new
      q.push(:item)
      expect(q.pop(timeout: 1.0)).to eq(:item)
    end

    it "returns the item when it is pushed before the timeout" do
      q = described_class.new
      Thread.new {
        sleep 0.02
        q.push(:late)
      }
      result = q.pop(timeout: 1.0)
      expect(result).to eq(:late)
    end
  end

  # Issue #329 — AsyncQueue must suspend the current Fiber (not the OS thread) when
  # pop is called in a DeterministicScheduler context.
  describe "cooperative pop (Issue #329)", :issue_329 do
    let(:scheduler) { Phronomy::Runtime::DeterministicScheduler.new }

    it "returns item pushed by another task without blocking the thread" do
      q = described_class.new
      results = []

      scheduler.spawn(name: "consumer", parent: nil) { results << q.pop }
      scheduler.spawn(name: "producer", parent: nil) { q.push(:hello) }
      scheduler.run_until_idle

      expect(results).to eq([:hello])
    end

    it "returns nil when timeout expires with an empty queue" do
      q = described_class.new
      result = :not_set

      scheduler.spawn(name: "consumer", parent: nil) { result = q.pop(timeout: 0) }
      scheduler.run_until_idle

      expect(result).to be_nil
    end

    it "transfers multiple items FIFO between cooperative tasks" do
      q = described_class.new
      results = []

      scheduler.spawn(name: "producers", parent: nil) do
        q.push(1)
        q.push(2)
        q.push(3)
      end
      scheduler.spawn(name: "consumer", parent: nil) do
        3.times { results << q.pop }
      end
      scheduler.run_until_idle

      expect(results).to eq([1, 2, 3])
    end
  end
end
