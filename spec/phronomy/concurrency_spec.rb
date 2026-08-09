# frozen_string_literal: true

require "spec_helper"

# ---------------------------------------------------------------------------
# Race / Concurrency tests for dispatch_parallel and VectorStore::InMemory
# (Issue #208)
# ---------------------------------------------------------------------------
RSpec.describe "Race / Concurrency (Issue #208)" do
  def stub_agent(output)
    out = output
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-96", version: 1
      define_method(:invoke) { |*| {output: out, messages: []} }
      define_method(:invoke_async) do |input, **_kw|
        Phronomy::Task.spawn(name: "stub-async") { invoke(input) }
      end
    end
  end

  describe "Orchestrator#dispatch_parallel result ordering under concurrency" do
    subject(:orchestrator) { Class.new(Phronomy::MultiAgent::Orchestrator).new }

    it "returns results in input order even when tasks complete in reverse order" do
      agents = (1..5).map do |i|
        delay = (5 - i) * 0.01
        Class.new(Phronomy::Agent::Base) do
          agent_definition id: "test-agent-97", version: 1
          define_method(:invoke) do |*|
            sleep delay
            {output: "task#{i}", messages: []}
          end
          define_method(:invoke_async) do |input, **_kw|
            Phronomy::Task.spawn(name: "stub-async") { invoke(input) }
          end
        end
      end

      tasks = agents.each_with_index.map { |a, i| {agent: a, input: "input#{i}"} }
      results = orchestrator.dispatch_parallel(*tasks)

      expect(results.map { |r| r[:output] }).to eq(%w[task1 task2 task3 task4 task5])
    end

    it "re-raises the first error in input order when a faster task also fails" do
      error_0 = RuntimeError.new("error from task 0 (slow)")
      error_2 = RuntimeError.new("error from task 2 (fast)")

      slow_fail = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-98", version: 1
        e = error_0
        define_method(:invoke) { |*|
          sleep 0.03
          raise e
        }
        define_method(:invoke_async) do |input, **_kw|
          Phronomy::Task.spawn(name: "stub-async") { invoke(input) }
        end
      end
      fast_fail = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-99", version: 1
        e = error_2
        define_method(:invoke) { |*| raise e }
        define_method(:invoke_async) do |input, **_kw|
          Phronomy::Task.spawn(name: "stub-async") { invoke(input) }
        end
      end
      good = stub_agent("ok")

      expect {
        orchestrator.dispatch_parallel(
          {agent: slow_fail, input: "0"},
          {agent: good, input: "1"},
          {agent: fast_fail, input: "2"},
          on_error: :raise
        )
      }.to raise_error(error_0)
    end

    it "does not exceed max_concurrency simultaneous threads" do
      peak_active = 0
      active = 0
      state_mutex = Mutex.new

      throttled = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-100", version: 1
        define_method(:invoke) do |*|
          state_mutex.synchronize do
            active += 1
            peak_active = active if active > peak_active
          end
          sleep 0.02
          state_mutex.synchronize { active -= 1 }
          {output: "ok", messages: []}
        end
        define_method(:invoke_async) do |input, **_kw|
          Phronomy::Task.spawn(name: "stub-async") { invoke(input) }
        end
      end

      tasks = 6.times.map { {agent: throttled, input: "x"} }
      orchestrator.dispatch_parallel(*tasks, max_concurrency: 2)

      expect(peak_active).to be <= 2
    end
  end

  describe "VectorStore::InMemory concurrent add/search integrity" do
    subject(:store) { Phronomy::VectorStore::InMemory.new(dimension: 3) }

    it "returns structurally valid results when add and search interleave" do
      5.times { |i| store.add(id: "seed-#{i}", embedding: [1.0, 0.0, 0.0], metadata: {i: i}) }

      invalid_results = []
      mutex = Mutex.new

      adder = Thread.new do
        50.times { |i| store.add(id: "new-#{i}", embedding: [rand, rand, rand], metadata: {i: i}) }
      end

      searcher = Thread.new do
        50.times do
          results = store.search(query_embedding: [1.0, 0.0, 0.0], k: 3)
          unless results.all? { |r| r.key?(:id) && r.key?(:score) && r.key?(:metadata) }
            mutex.synchronize { invalid_results << results }
          end
        end
      end

      adder.join
      searcher.join

      expect(invalid_results).to be_empty
    end
  end
end
