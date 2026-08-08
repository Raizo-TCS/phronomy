# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Group 38: :fiber backend cooperative runtime (Issue #339)
# Factor: fb_subject (12 values, each = 1 test case)
#
# Feasible cases: 12 (TC-001..TC-012)
# Infeasible: none
#
# TC-001..TC-007: DeterministicScheduler low-level primitives — no LLM required.
# TC-008..TC-012: Upper-layer components (Agent, LLMAdapter, ToolExecutor,
#                 VectorStore, AsyncQueue streaming) — TC-008/TC-009 use LLMStub.

RSpec.describe "Group 38: :fiber backend cooperative runtime", :integration do
  # Build a fresh DeterministicScheduler-backed runtime for each example.
  let(:scheduler) { Phronomy::Runtime::DeterministicScheduler.new(autorun: true) }
  let(:runtime) { Phronomy::Runtime.new(scheduler: scheduler) }

  # -------------------------------------------------------------------------
  # TC-001: spawn_await_value — spawn + await returns the task's return value
  # -------------------------------------------------------------------------
  describe "TC-001: spawn_await_value — spawn + await returns the task's return value" do
    it "task.wait_result returns the value produced by the spawned block" do
      task = runtime.spawn(name: "value-task") { 42 }
      expect(task.wait_result).to eq(42)
    end
  end

  # -------------------------------------------------------------------------
  # TC-002: blocking_io_await — PendingOperation#await suspends cooperatively
  # -------------------------------------------------------------------------
  describe "TC-002: blocking_io_await — PendingOperation#await suspends cooperatively" do
    let(:pool) { Phronomy::Concurrency::BlockingAdapterPool.new(pool_size: 2, queue_size: 10) }

    after { pool.shutdown(drain_timeout: 2) }

    it "awaiting Fiber resumes after the worker thread completes the operation" do
      result = nil
      runtime.spawn(name: "io-task") do
        op = pool.submit { :from_worker }
        result = op.blocking_wait
      end
      expect(result).to eq(:from_worker)
    end

    it "does not block the scheduler while the worker is running" do
      order = []

      # Both children are spawned inside a parent orchestrator so they run
      # within a single run_until_idle loop.  Spawning from the top level in
      # autorun mode would call run_until_idle once per spawn (serialising the
      # tasks), which would defeat the concurrency assertion.
      runtime.spawn(name: "orchestrator") do
        slow_task = runtime.spawn(name: "slow-task") do
          op = pool.submit do
            sleep 0.05
            :slow_result
          end
          order << :before_await
          op.blocking_wait
          order << :after_await
        end

        fast_task = runtime.spawn(name: "fast-task") do
          order << :fast_ran
        end

        slow_task.wait_result
        fast_task.wait_result
      end

      # fast-task must run while slow-task is suspended in op.blocking_wait
      expect(order).to include(:fast_ran)
      expect(order.index(:fast_ran)).to be < order.index(:after_await)
      expect(order.first).to eq(:before_await)
    end
  end

  # -------------------------------------------------------------------------
  # TC-003: async_queue_pop — AsyncQueue#pop suspends cooperatively
  # -------------------------------------------------------------------------
  describe "TC-003: async_queue_pop — AsyncQueue#pop suspends cooperatively" do
    it "consumer task resumes when producer pushes a value" do
      queue = Phronomy::Concurrency::AsyncQueue.new
      received = nil

      runtime.spawn(name: "consumer") do
        received = queue.pop
      end

      runtime.spawn(name: "producer") do
        queue.push(:hello)
      end

      expect(received).to eq(:hello)
    end
  end

  # -------------------------------------------------------------------------
  # TC-004: spawn_child — child task completes before parent resumes
  # -------------------------------------------------------------------------
  describe "TC-004: spawn_child — child task completes before parent resumes" do
    it "parent task awaits the child task's result cooperatively" do
      parent_result = nil

      runtime.spawn(name: "parent") do
        child = runtime.spawn(name: "child") { :child_value }
        parent_result = child.wait_result
      end

      expect(parent_result).to eq(:child_value)
    end
  end

  # -------------------------------------------------------------------------
  # TC-005: error_propagation — exception from spawned block propagates through await
  # -------------------------------------------------------------------------
  describe "TC-005: error_propagation — exception propagates through task.wait_result" do
    it "raises the original exception class and message in the awaiting fiber" do
      raised = nil

      runtime.spawn(name: "catcher") do
        child = runtime.spawn(name: "raiser") { raise ArgumentError, "fiber error" }
        begin
          child.wait_result
        rescue ArgumentError => e
          raised = e
        end
      end

      expect(raised).to be_a(ArgumentError)
      expect(raised.message).to eq("fiber error")
    end
  end

  # -------------------------------------------------------------------------
  # TC-006: cancellation — task.cancel! transitions the task to :cancelled
  # -------------------------------------------------------------------------
  describe "TC-006: cancellation — task.cancel! transitions the task to :cancelled" do
    it "the task transitions to :cancelled when cancel! is called" do
      cancelled_status = nil

      runtime.spawn(name: "orchestrator") do
        child = runtime.spawn(name: "cancellable") do
          # Block on an inner spawn to create a cooperative yield point;
          # the task is scheduled but not yet dispatched when cancel! fires.
          inner = runtime.spawn(name: "inner") { :inner_value }
          inner.wait_result
          :should_not_reach
        end

        # cancel! transitions the task to :cancelled immediately (via
        # Task#transition!) before the scheduler dispatches the child fiber.
        child.cancel!
        cancelled_status = child.status
      end

      expect(cancelled_status).to eq(:cancelled)
    end
  end

  # -------------------------------------------------------------------------
  # TC-007: timer_real_clock — SchedulerTimerAdapter fires after real deadline
  # -------------------------------------------------------------------------
  describe "TC-007: timer_real_clock — real-clock timer fires automatically via run_until_idle" do
    let(:timer_adapter) { Phronomy::Runtime::SchedulerTimerAdapter.new(scheduler) }

    it "fires the callback after the wall-clock deadline has passed (Issue #337)" do
      fired_at = nil
      scheduled_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      timer_adapter.schedule(seconds: 0.05) do
        fired_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Spawn a no-op task so run_until_idle is triggered via autorun.
      # The scheduler sleeps until the 50ms deadline, fires the timer, then returns.
      runtime.spawn(name: "noop") { nil }

      expect(fired_at).not_to be_nil
      expect(fired_at - scheduled_at).to be >= 0.04
    end
  end

  # ---------------------------------------------------------------------------
  # Upper-layer component tests (TC-008..TC-012)
  # Runtime.instance is set to the DeterministicScheduler-backed runtime for
  # each example so that Agent, ToolExecutor and VectorStore all route through
  # the same scheduler/pool under test.
  # ---------------------------------------------------------------------------

  # TC-008: agent_invoke_async
  # -------------------------------------------------------------------------
  describe "TC-008: agent_invoke_async — Agent#invoke and #invoke_async return correct result under :fiber" do
    let(:agent_class) do
      Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-5", version: 1
        model "openai/gpt-oss-20b"
        provider :openai
        instructions "You are a test assistant."
      end
    end

    around do |ex|
      old = Phronomy::Runtime.replace_default_for_test(runtime)
      ex.run
    ensure
      begin
        runtime.shutdown(timeout: 5)
      rescue
        nil
      end
      Phronomy::Runtime.restore_default_for_test(old)
    end

    before { LLMStub.activate(responses: ["Hello from fiber!"]) }
    after { LLMStub.deactivate }

    it "invoke returns a Hash with non-empty :output String" do
      result = agent_class.new.invoke("hello")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end

    it "invoke_async returns a Task; await resolves to the same result structure" do
      result = agent_class.new.invoke_async("hello").wait_result
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # TC-009: llm_adapter_suspend
  # -------------------------------------------------------------------------
  describe "TC-009: llm_adapter_suspend — LLMAdapter#complete_async suspends cooperatively under :fiber" do
    let(:agent_class) do
      Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-6", version: 1
        model "openai/gpt-oss-20b"
        provider :openai
        instructions "You are a test assistant."
      end
    end

    around do |ex|
      old = Phronomy::Runtime.replace_default_for_test(runtime)
      ex.run
    ensure
      begin
        runtime.shutdown(timeout: 5)
      rescue
        nil
      end
      Phronomy::Runtime.restore_default_for_test(old)
    end

    before { LLMStub.activate(responses: ["LLM response"]) }
    after { LLMStub.deactivate }

    it "fast fiber runs while LLM call is pending in the pool" do
      order = []

      runtime.spawn(name: "orchestrator") do
        slow_task = runtime.spawn(name: "llm-task") do
          order << :before_llm
          agent_class.new.invoke_async("query").wait_result
          order << :after_llm
        end

        fast_task = runtime.spawn(name: "fast-task") do
          order << :fast_ran
        end

        slow_task.wait_result
        fast_task.wait_result
      end

      expect(order).to include(:fast_ran)
      expect(order.index(:fast_ran)).to be < order.index(:after_llm)
    end
  end

  # TC-010: mixed_tools
  # -------------------------------------------------------------------------
  describe "TC-010: mixed_tools — FbBlockingTool (:blocking_io) and FbCooperativeTool (:cooperative) both execute correctly under :fiber" do
    around do |ex|
      old = Phronomy::Runtime.replace_default_for_test(runtime)
      ex.run
    ensure
      begin
        runtime.shutdown(timeout: 5)
      rescue
        nil
      end
      Phronomy::Runtime.restore_default_for_test(old)
    end

    it "FbBlockingTool#call_async routes through the pool and returns the correct result" do
      result = nil
      runtime.spawn(name: "blocking-caller") do
        result = IntegrationFactors::FbBlockingTool.new.call_async({input: "x"}).wait_result
      end
      expect(result).to eq("blocking:x")
    end

    it "FbCooperativeTool#call_async routes through Runtime#spawn and returns the correct result" do
      result = nil
      runtime.spawn(name: "coop-caller") do
        result = IntegrationFactors::FbCooperativeTool.new.call_async({input: "y"}).wait_result
      end
      expect(result).to eq("cooperative:y")
    end

    it "both tools can be called concurrently and both resolve correctly" do
      results = []
      runtime.spawn(name: "orchestrator") do
        t1 = IntegrationFactors::FbBlockingTool.new.call_async({input: "a"})
        t2 = IntegrationFactors::FbCooperativeTool.new.call_async({input: "b"})
        results << t1.wait_result
        results << t2.wait_result
      end
      expect(results).to contain_exactly("blocking:a", "cooperative:b")
    end
  end

  # TC-011: rag_fetch
  # -------------------------------------------------------------------------
  describe "TC-011: rag_fetch — VectorStore::InMemory#search_async routes through pool and returns correct results under :fiber" do
    around do |ex|
      old = Phronomy::Runtime.replace_default_for_test(runtime)
      ex.run
    ensure
      begin
        runtime.shutdown(timeout: 5)
      rescue
        nil
      end
      Phronomy::Runtime.restore_default_for_test(old)
    end

    it "search_async awaited inside a spawned fiber returns the correct top result" do
      store = Phronomy::VectorStore::InMemory.new
      store.add(id: "doc1", embedding: [1.0, 0.0, 0.0], metadata: {content: "hello"})
      store.add(id: "doc2", embedding: [0.0, 1.0, 0.0], metadata: {content: "world"})

      result = nil
      runtime.spawn(name: "searcher") do
        results = store.search_async(query_embedding: [1.0, 0.0, 0.0], k: 1).wait_result
        result = results.first
      end

      expect(result).not_to be_nil
      expect(result[:id]).to eq("doc1")
    end
  end

  # TC-012: stream_queue
  # -------------------------------------------------------------------------
  describe "TC-012: stream_queue — tokens flow through AsyncQueue and :done is the final event" do
    it "cooperative producer pushes tokens then a nil sentinel; consumer collects :token/:done events in order" do
      tokens = %w[hello world]
      queue = Phronomy::Concurrency::AsyncQueue.new
      events = []

      runtime.spawn(name: "orchestrator") do
        consumer_task = runtime.spawn(name: "consumer") do
          loop do
            item = queue.pop
            break if item.nil?
            events << {type: :token, content: item}
          end
          events << {type: :done}
        end

        producer_task = runtime.spawn(name: "producer") do
          tokens.each { |t| queue.push(t) }
          queue.push(nil) # nil sentinel wakes the waiting consumer and signals end-of-stream
        end

        producer_task.wait_result
        consumer_task.wait_result
      end

      expect(events.map { |e| e[:type] }).to eq([:token, :token, :done])
      expect(events.select { |e| e[:type] == :token }.map { |e| e[:content] }).to eq(tokens)
      expect(events.last[:type]).to eq(:done)
    end
  end
end
