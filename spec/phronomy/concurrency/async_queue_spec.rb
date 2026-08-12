# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Concurrency::AsyncQueue do
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

  # Issue #284 — EventLoop and CancellationScope must not reference Thread::Queue
  # directly; all queue usage must go through Phronomy::Concurrency::AsyncQueue so the backing
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

  # Issue #347 — pop timeout semantics differ between thread and cooperative paths.
  # Thread path uses wall-clock time.
  describe "pop timeout semantics: wall-clock (Issue #347)", :issue_347 do
    context "thread path (wall-clock)" do
      it "returns nil after real elapsed time when queue stays empty" do
        q = described_class.new
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = q.pop(timeout: 0.03)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        expect(result).to be_nil
        expect(elapsed).to be >= 0.02
      end

      it "does not expire before the item arrives within the timeout window" do
        q = described_class.new
        Thread.new do
          sleep 0.01
          q.push(:ok)
        end
        expect(q.pop(timeout: 2.0)).to eq(:ok)
      end
    end
  end
end
