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

  # Issue #336 — AsyncQueue#push must not block the OS thread when SizedQueue is
  # full in a cooperative scheduler context; it should suspend the Fiber instead.
  describe "cooperative bounded-queue push backpressure (Issue #336)", :issue_336 do
    let(:scheduler) { Phronomy::Runtime::DeterministicScheduler.new }

    it "suspends the producer Fiber when the queue is full and resumes when a slot opens" do
      q = described_class.new(max_size: 1)
      log = []

      scheduler.spawn(name: "producer", parent: nil) do
        q.push(:first)
        log << :pushed_first
        q.push(:second)   # queue full — suspends cooperatively until consumer pops
        log << :pushed_second
      end

      scheduler.spawn(name: "consumer", parent: nil) do
        log << q.pop   # :first — frees a slot, wakes producer
        log << q.pop   # :second
      end

      scheduler.run_until_idle

      expect(log).to eq([:pushed_first, :first, :pushed_second, :second])
    end

    it "transfers multiple items through a bounded queue cooperatively" do
      q = described_class.new(max_size: 2)
      results = []

      scheduler.spawn(name: "producer", parent: nil) do
        5.times { |i| q.push(i) }
      end
      scheduler.spawn(name: "consumer", parent: nil) do
        5.times { results << q.pop }
      end

      scheduler.run_until_idle
      expect(results).to eq([0, 1, 2, 3, 4])
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

  # Issue #347 — pop timeout semantics differ between thread and cooperative paths.
  # Thread path uses wall-clock time; cooperative/fiber path uses virtual time.
  describe "pop timeout semantics: wall-clock vs virtual-time (Issue #347)", :issue_347 do
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

    context "cooperative path (virtual time)" do
      let(:scheduler) { Phronomy::Runtime::DeterministicScheduler.new }

      it "expires immediately when virtual time already meets the deadline" do
        q = described_class.new
        result = :not_set

        scheduler.spawn(name: "consumer", parent: nil) do
          result = q.pop(timeout: 0)
        end
        scheduler.run_until_idle

        expect(result).to be_nil
      end

      it "expires when queue is still empty at or past the timeout deadline" do
        q = described_class.new
        result = :not_set

        scheduler.spawn(name: "consumer", parent: nil) do
          result = q.pop(timeout: 0)
        end
        # advance has no effect on waking the consumer here — timeout: 0 means
        # the deadline (virtual_time + 0) is already met on the first loop check.
        scheduler.advance(1.0)
        scheduler.run_until_idle

        expect(result).to be_nil
      end

      it "returns nil (not the item) when a producer wakes the consumer after deadline" do
        # The cooperative deadline is checked *after* wait_for_signal returns.
        # So even if a producer pushes an item, if virtual_time >= deadline at
        # the moment the consumer is woken up, it returns nil and does not
        # dequeue the item.
        q = described_class.new
        result = :not_set

        scheduler.spawn(name: "consumer", parent: nil) do
          result = q.pop(timeout: 0.5)  # deadline = 0.0 + 0.5 = 0.5
        end
        scheduler.tick  # consumer runs to wait_for_signal (deadline not yet met)
        scheduler.advance(1.0)  # virtual_time = 1.0, past the deadline

        # Producer push wakes the consumer via @coop_signal.
        # Consumer checks: virtual_time (1.0) >= deadline (0.5) => return nil.
        scheduler.spawn(name: "producer", parent: nil) { q.push(:too_late) }
        scheduler.run_until_idle

        expect(result).to be_nil
      end

      it "does NOT expire just because real time passes (virtual time unchanged)" do
        q = described_class.new
        result = :not_set
        pushed = false

        scheduler.spawn(name: "producer", parent: nil) do
          q.push(:virtual_item)
          pushed = true
        end
        scheduler.spawn(name: "consumer", parent: nil) do
          result = q.pop(timeout: 999.0)
        end
        scheduler.run_until_idle

        expect(pushed).to be true
        expect(result).to eq(:virtual_item)
      end
    end
  end
end
