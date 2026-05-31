# frozen_string_literal: true

RSpec.describe Phronomy::Concurrency::ConcurrencyGate do
  describe "unlimited gate (max_concurrent: nil)" do
    subject(:gate) { described_class.new(max_concurrent: nil, name: :test) }

    it "passes through without counting" do
      result = gate.acquire { :ok }
      expect(result).to eq(:ok)
    end

    it "allows unlimited concurrent calls without blocking" do
      results = 20.times.map { gate.acquire { :done } }
      expect(results).to all eq(:done)
    end

    it "current_count is always 0 when unlimited" do
      gate.acquire { expect(gate.current_count).to eq(0) }
    end
  end

  describe "capped gate (max_concurrent: N)" do
    subject(:gate) { described_class.new(max_concurrent: 2, name: :test) }

    it "allows up to max_concurrent simultaneous acquisitions" do
      results = []
      mutex = Mutex.new
      cond = ConditionVariable.new
      holding = 0

      threads = 2.times.map do
        Thread.new do
          gate.acquire do
            mutex.synchronize do
              holding += 1
              cond.broadcast
              cond.wait(mutex, 1) until holding >= 2
            end
            results << :done
          end
        end
      end
      threads.each(&:join)
      expect(results.size).to eq(2)
    end

    it "tracks current_count correctly" do
      barrier = Mutex.new
      cond = ConditionVariable.new
      inside = false

      t = Thread.new do
        gate.acquire do
          barrier.synchronize {
            inside = true
            cond.broadcast
          }
          sleep(0.1)
        end
      end

      barrier.synchronize { cond.wait(barrier, 1) until inside }
      expect(gate.current_count).to eq(1)
      t.join
      expect(gate.current_count).to eq(0)
    end

    it "releases the slot even when the block raises" do
      expect { gate.acquire { raise "boom" } }.to raise_error("boom")
      expect(gate.current_count).to eq(0)
    end

    describe "on_full: :reject" do
      it "raises BackpressureError immediately when at capacity" do
        gate = described_class.new(max_concurrent: 1, name: :test)
        barrier = Mutex.new
        cond = ConditionVariable.new
        inside = false

        t = Thread.new do
          gate.acquire do
            barrier.synchronize {
              inside = true
              cond.broadcast
            }
            sleep(0.5)
          end
        end
        barrier.synchronize { cond.wait(barrier, 1) until inside }

        expect {
          gate.acquire(on_full: :reject) { :second }
        }.to raise_error(Phronomy::BackpressureError, /capacity/)
      ensure
        t&.join
      end
    end

    describe "on_full: :timeout" do
      it "raises BackpressureError after timeout expires" do
        gate = described_class.new(max_concurrent: 1, name: :test)
        barrier = Mutex.new
        cond = ConditionVariable.new
        inside = false

        t = Thread.new do
          gate.acquire do
            barrier.synchronize {
              inside = true
              cond.broadcast
            }
            sleep(0.5)
          end
        end
        barrier.synchronize { cond.wait(barrier, 1) until inside }

        expect {
          gate.acquire(on_full: :timeout, timeout: 0.05) { :second }
        }.to raise_error(Phronomy::BackpressureError, /timed out/)
      ensure
        t&.join
      end
    end

    describe "on_full: :wait" do
      it "blocks until a slot is free, then executes" do
        gate = described_class.new(max_concurrent: 1, name: :test)
        barrier = Mutex.new
        cond = ConditionVariable.new
        inside = false

        t = Thread.new do
          gate.acquire do
            barrier.synchronize {
              inside = true
              cond.broadcast
            }
            sleep(0.05)
          end
        end
        barrier.synchronize { cond.wait(barrier, 1) until inside }

        result = gate.acquire(on_full: :wait) { :waited }
        expect(result).to eq(:waited)
        t.join
      end
    end
  end

  describe "Runtime#gate integration" do
    before { Phronomy::Runtime.instance.reset_gate(:agent) }
    after do
      Phronomy.configuration.max_concurrent_agent_tasks = nil
      Phronomy::Runtime.instance.reset_gate(:agent)
    end

    it "returns an unlimited gate when max_concurrent_agent_tasks is nil" do
      Phronomy.configuration.max_concurrent_agent_tasks = nil
      gate = Phronomy::Runtime.instance.gate(:agent)
      expect(gate.max).to be_nil
    end

    it "returns a capped gate when max_concurrent_agent_tasks is set" do
      Phronomy.configuration.max_concurrent_agent_tasks = 3
      gate = Phronomy::Runtime.instance.gate(:agent)
      expect(gate.max).to eq(3)
    end

    it "caches the gate across calls" do
      gate1 = Phronomy::Runtime.instance.gate(:agent)
      gate2 = Phronomy::Runtime.instance.gate(:agent)
      expect(gate1).to be(gate2)
    end

    it "reset_gate clears the cached gate" do
      gate1 = Phronomy::Runtime.instance.gate(:agent)
      Phronomy::Runtime.instance.reset_gate(:agent)
      gate2 = Phronomy::Runtime.instance.gate(:agent)
      expect(gate1).not_to be(gate2)
    end
  end

  describe "Configuration max_concurrent_* fields" do
    subject(:config) { Phronomy::Configuration.new }

    it "defaults all max_concurrent_* fields to nil" do
      expect(config.max_concurrent_agent_tasks).to be_nil
      expect(config.max_concurrent_tool_tasks).to be_nil
      expect(config.max_concurrent_workflow_tasks).to be_nil
      expect(config.max_concurrent_llm_calls).to be_nil
      expect(config.max_concurrent_vector_searches).to be_nil
    end

    it "allows setting max_concurrent_agent_tasks" do
      config.max_concurrent_agent_tasks = 5
      expect(config.max_concurrent_agent_tasks).to eq(5)
    end
  end
end
