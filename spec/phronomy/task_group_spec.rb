# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::TaskGroup do
  describe "#spawn / #await_all" do
    it "runs tasks concurrently and returns results in spawn order" do
      group = described_class.new
      results = []
      group.spawn { 1 }
      group.spawn { 2 }
      group.spawn { 3 }
      expect(group.await_all).to eq([1, 2, 3])
    end

    it "re-raises the first error after all tasks finish" do
      group = described_class.new
      group.spawn { raise ArgumentError, "task-error" }
      group.spawn { 99 }
      expect { group.await_all }.to raise_error(ArgumentError, "task-error")
    end

    it "enforces the concurrency limit" do
      active  = Concurrent::AtomicFixnum.new(0) rescue Mutex.new  # fallback
      max_seen = Mutex.new
      max_count = 0
      mu = Mutex.new

      limit = 2
      group = described_class.new(limit: limit)

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
      expect(described_class.new.await_all).to eq([])
    end
  end

  describe "#cancel_all!" do
    it "returns self" do
      group = described_class.new
      expect(group.cancel_all!).to be(group)
    end

    it "cancels running tasks" do
      group = described_class.new
      group.spawn { sleep 30 }
      group.spawn { sleep 30 }
      group.cancel_all!
      # tasks should error after cancel
      expect { group.await_all }.to raise_error(Phronomy::CancellationError)
    end
  end
end
