# frozen_string_literal: true

require "spec_helper"

# ---------------------------------------------------------------------------
# Race / Concurrency tests for dispatch_parallel and VectorStore::InMemory
# (Issue #208)
# ---------------------------------------------------------------------------
RSpec.describe "Race / Concurrency (Issue #208)" do
  def stub_agent(output)
    Class.new(Phronomy::Agent::Base) do
      define_method(:_invoke_impl) { |*| {output: output, messages: []} }
    end
  end

  # -----------------------------------------------------------------------
  # Orchestrator#dispatch_parallel — result ordering under real concurrency
  # -----------------------------------------------------------------------
  describe "Orchestrator#dispatch_parallel result ordering under concurrency" do
    subject(:orchestrator) { Class.new(Phronomy::Agent::Orchestrator).new }

    it "returns results in input order even when tasks complete in reverse order" do
      # Tasks are staggered so they finish in reverse order (task 5 first, task 1 last).
      # The implementation must still return results[0..4] in input order.
      agents = (1..5).map do |i|
        delay = (5 - i) * 0.01
        Class.new(Phronomy::Agent::Base) do
          define_method(:_invoke_impl) do |*|
            sleep delay
            {output: "task#{i}", messages: []}
          end
        end
      end

      tasks = agents.each_with_index.map { |a, i| {agent: a, input: "input#{i}"} }
      results = orchestrator.dispatch_parallel(*tasks)

      expect(results.map { |r| r[:output] }).to eq(%w[task1 task2 task3 task4 task5])
    end

    it "re-raises the first error in input order when a faster task also fails" do
      # Task 2 fails immediately; task 0 fails after a delay.
      # The re-raised error must be task 0's (input order takes precedence).
      error_0 = RuntimeError.new("error from task 0 (slow)")
      error_2 = RuntimeError.new("error from task 2 (fast)")

      slow_fail = Class.new(Phronomy::Agent::Base) do
        e = error_0
        define_method(:_invoke_impl) { |*|
          sleep 0.03
          raise e
        }
      end
      fast_fail = Class.new(Phronomy::Agent::Base) do
        e = error_2
        define_method(:_invoke_impl) { |*| raise e }
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
        define_method(:_invoke_impl) do |*|
          state_mutex.synchronize do
            active += 1
            peak_active = active if active > peak_active
          end
          sleep 0.02
          state_mutex.synchronize { active -= 1 }
          {output: "ok", messages: []}
        end
      end

      tasks = 6.times.map { {agent: throttled, input: "x"} }
      orchestrator.dispatch_parallel(*tasks, max_concurrency: 2)

      expect(peak_active).to be <= 2
    end
  end

  # -----------------------------------------------------------------------
  # Orchestrator#invoke_once — instance-variable context is cleaned up after
  # invoke completes (Issue #208, updated for #259: replaced Thread.current key
  # with @_orchestrator_context instance variable)
  # -----------------------------------------------------------------------
  describe "Orchestrator#invoke_once context cleanup" do
    it "resets @_orchestrator_context to nil after invoke" do
      orchestrator_class = Class.new(Phronomy::Agent::Orchestrator)
      # Override to avoid any real LLM call; just return immediately.
      orchestrator_class.define_method(:_invoke_impl) do |input, config: {}, thread_id: nil, **|
        super(input, config: config, thread_id: thread_id)
      rescue
        {output: "done", messages: []}
      end

      orchestrator = orchestrator_class.new
      # Calling invoke may set @_orchestrator_context; the ensure block must restore nil.
      begin
        orchestrator.send(:invoke_once, "test", thread_id: "t1", config: {}, messages: [])
      rescue
        # Ignore invocation errors (no real LLM) — we only care about cleanup.
      end

      expect(orchestrator.instance_variable_get(:@_orchestrator_context)).to be_nil
    end
  end

  # -----------------------------------------------------------------------
  # VectorStore::InMemory — concurrent add / search isolation
  # (already partially covered in in_memory_spec; this adds search-result
  #  integrity assertions missing from that suite)
  # -----------------------------------------------------------------------
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
