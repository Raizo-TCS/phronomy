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
      q     = described_class.new
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
      q       = described_class.new(max_size: 1)
      q.push(:first)
      blocked = false
      t       = Thread.new do
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
end
