# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Group 37: BlockingAdapterPool boundary
# Factor: bb_subject (9 values, each = 1 test case)
#
# Feasible cases: 8 (TC-001..TC-008)
# Infeasible:
#   TC-009 (stream_callback): SKIP — depends on Issue #292 (streaming callback
#     via AsyncQueue not yet implemented; callbacks still run on worker thread)
#
# No LLM required: all cases use LLMStub (WebMock) or pure-Ruby pool calls.

# Counts pool.submit invocations for the duration of a block.
# Wraps the pool's #submit method and restores it on exit.
module PoolSpy
  # Instruments +pool+ and yields a counter array (grows by 1 per submit call).
  # The original #submit behaviour is preserved.
  def self.instrument(pool)
    counts = []
    original = pool.method(:submit)
    pool.define_singleton_method(:submit) do |**kwargs, &blk|
      counts << true
      original.call(**kwargs, &blk)
    end
    yield counts
  ensure
    # Remove the singleton override so the pool is reusable across examples.
    class << pool
      remove_method :submit
    end
  end
end

RSpec.describe "Group 37: BlockingAdapterPool boundary", :integration do
  # Ensure a fresh Runtime pool for each example so spy state does not leak.
  around(:each) do |example|
    old_runtime = Phronomy::Runtime.instance
    Phronomy::Runtime.instance = Phronomy::Runtime.new
    example.run
  ensure
    # Shut down the per-example runtime pool gracefully.
    Phronomy::Runtime.instance.blocking_io.shutdown(drain_timeout: 5)
    Phronomy::Runtime.instance = old_runtime
  end

  let(:pool) { Phronomy::Runtime.instance.blocking_io }

  # -------------------------------------------------------------------------
  # TC-001: agent_llm — Agent LLM call routes through BlockingAdapterPool
  # -------------------------------------------------------------------------
  describe "TC-001: agent_llm — Agent LLM call routes through BlockingAdapterPool" do
    let(:agent_class) do
      Class.new(Phronomy::Agent::Base) do
        model "openai/gpt-oss-20b"
        provider :openai
        instructions "You are a test assistant."
      end
    end

    before { @llm = LLMStub.activate(responses: ["Hello!"]) }
    after { LLMStub.deactivate }

    it "routes the LLM call through pool.submit" do
      PoolSpy.instrument(pool) do |counts|
        result = agent_class.new.invoke("say hi")
        expect(result[:output]).to be_a(String)
        expect(counts.size).to be >= 1
      end
    end
  end

  # -------------------------------------------------------------------------
  # TC-002: blocking_io_tool — :blocking_io tool routes through pool
  # -------------------------------------------------------------------------
  describe "TC-002: blocking_io_tool — :blocking_io tool routes through pool" do
    let(:agent_class) do
      tool = IntegrationFactors::BbBlockingTool
      Class.new(Phronomy::Agent::Base) do
        model "openai/gpt-oss-20b"
        provider :openai
        instructions "Call the tool with input 'hello'."
        tools tool
      end
    end

    before do
      # Enable EventLoop mode so ParallelToolChat is used as the chat class.
      # This makes Phase 2 (pool.submit dispatch) active for :blocking_io tools.
      Phronomy.configure { |c| c.event_loop = true }

      # Two tool calls in a single response trigger Phase 2 (parallel dispatch)
      # in ParallelToolChat#handle_tool_calls, which routes each via pool.submit.
      two_calls = {
        "id" => "chatcmpl-stub-0", "object" => "chat.completion", "created" => 0,
        "model" => "stub-model",
        "choices" => [{
          "index" => 0,
          "message" => {
            "role" => "assistant", "content" => nil,
            "tool_calls" => [
              {"id" => "call_1", "type" => "function",
               "function" => {"name" => "bb_blocking_tool", "arguments" => '{"input":"hello"}'}},
              {"id" => "call_2", "type" => "function",
               "function" => {"name" => "bb_blocking_tool", "arguments" => '{"input":"world"}'}}
            ]
          },
          "logprobs" => nil, "finish_reason" => "tool_calls"
        }],
        "usage" => {"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }
      @llm = LLMStub.activate(responses: [two_calls, "Done"])
    end
    after do
      LLMStub.deactivate
      Phronomy.reset_configuration!
    end

    it "routes the :blocking_io tool call through pool.submit" do
      PoolSpy.instrument(pool) do |counts|
        result = agent_class.new.invoke("run tools")
        expect(result[:output]).to be_a(String)
        # Phase 2 submits each :blocking_io tool via pool.submit,
        # plus the LLM call itself routes via pool.submit (complete_async).
        # With 2 tool calls: at minimum 1 (complete_async) + 2 (tool dispatch) = 3.
        expect(counts.size).to be >= 2
      end
    end
  end

  # -------------------------------------------------------------------------
  # TC-003: cooperative_tool — :cooperative tool does NOT use pool
  # -------------------------------------------------------------------------
  describe "TC-003: cooperative_tool — :cooperative tool does NOT use BlockingAdapterPool" do
    let(:agent_class) do
      tool = IntegrationFactors::BbCooperativeTool
      Class.new(Phronomy::Agent::Base) do
        model "openai/gpt-oss-20b"
        provider :openai
        instructions "Call the cooperative tool with input 'test'."
        tools tool
      end
    end

    before do
      tool_resp = LLMStub.tool_call_response("bb_cooperative_tool", {input: "test"})
      @llm = LLMStub.activate(responses: [tool_resp, "Done"])
    end
    after { LLMStub.deactivate }

    it "does NOT submit the cooperative tool call to pool.submit" do
      # Patch only the tool-call path: count pool submissions attributed to tool
      # dispatch by measuring before and after the agent call excluding the LLM
      # submissions (which always use the pool).
      #
      # Strategy: run without tool first to get baseline LLM submissions, then
      # check that tool execution does not add extra pool submissions.
      #
      # Simpler approach: spy on pool.submit and record caller locations.
      calls_before_tool = []
      original = pool.method(:submit)
      pool.define_singleton_method(:submit) do |**kwargs, &blk|
        calls_before_tool << caller(1, 1).first
        original.call(**kwargs, &blk)
      end

      result = agent_class.new.invoke("run cooperative tool")
      expect(result[:output]).to be_a(String)

      # None of the pool.submit callers should originate from parallel_tool_chat.
      tool_dispatches = calls_before_tool.select { |loc| loc.include?("parallel_tool_chat") }
      expect(tool_dispatches).to be_empty
    ensure
      class << pool
        remove_method :submit
      end
    end
  end

  # -------------------------------------------------------------------------
  # TC-004: rag_fetch — RAG fetch routes through pool
  # -------------------------------------------------------------------------
  describe "TC-004: rag_fetch — KnowledgeSource#fetch_async routes through pool" do
    # Use a minimal custom KnowledgeSource to avoid requiring a real
    # embeddings adapter. fetch_async is inherited from Base and always
    # submits to pool.submit regardless of subclass.
    let(:knowledge_source) do
      Class.new(Phronomy::Agent::Context::Knowledge::Source::Base) do
        def fetch(query: nil, cancellation_token: nil)
          [{content: "Test content.", type: :text, source: "test"}]
        end
      end.new
    end

    it "routes KnowledgeSource#fetch_async through pool.submit" do
      PoolSpy.instrument(pool) do |counts|
        result = knowledge_source.fetch_async(query: "anything").await
        expect(result).to be_an(Array)
        expect(result.first[:content]).to eq("Test content.")
        expect(counts.size).to eq(1)
      end
    end
  end

  # -------------------------------------------------------------------------
  # TC-005: vector_store — VectorStore#search_async routes through pool
  # -------------------------------------------------------------------------
  describe "TC-005: vector_store — VectorStore::Base#search_async routes through pool" do
    let(:vector_store) { Phronomy::Agent::Context::Knowledge::VectorStore::InMemory.new }

    before do
      vector_store.add(id: "v1", embedding: [0.5, 0.5], metadata: {content: "test"})
    end

    it "routes search_async through pool.submit" do
      PoolSpy.instrument(pool) do |counts|
        result = vector_store.search_async(query_embedding: [0.5, 0.5], k: 1).await
        expect(result).to be_an(Array)
        expect(counts.size).to eq(1)
      end
    end
  end

  # -------------------------------------------------------------------------
  # TC-006: queue_full — Pool queue full raises BackpressureError
  # -------------------------------------------------------------------------
  describe "TC-006: queue_full — pool queue full raises BackpressureError" do
    # Use a tiny pool (1 worker, 1-deep queue) so saturation is easy.
    let(:tiny_pool) { Phronomy::Concurrency::BlockingAdapterPool.new(pool_size: 1, queue_size: 1) }

    after { tiny_pool.shutdown(drain_timeout: 3) }

    it "raises BackpressureError when the queue is full and on_full: :raise" do
      barrier = Mutex.new
      cond = ConditionVariable.new
      hold = true

      # Fill the worker.
      tiny_pool.submit { barrier.synchronize { cond.wait(barrier) while hold } }
      # Fill the queue.
      tiny_pool.submit { "queued" }

      # Third submit must raise immediately.
      expect {
        tiny_pool.submit(on_full: :raise) { "overflow" }
      }.to raise_error(Phronomy::BackpressureError)
    ensure
      barrier.synchronize {
        hold = false
        cond.broadcast
      }
    end
  end

  # -------------------------------------------------------------------------
  # TC-007: pool_shutdown — Submit after shutdown raises PoolShutdownError
  # -------------------------------------------------------------------------
  describe "TC-007: pool_shutdown — submit after shutdown raises PoolShutdownError" do
    let(:fresh_pool) { Phronomy::Concurrency::BlockingAdapterPool.new(pool_size: 1, queue_size: 10) }

    it "raises PoolShutdownError when the pool has been shut down" do
      fresh_pool.shutdown(drain_timeout: 3)
      expect {
        fresh_pool.submit { "too late" }
      }.to raise_error(Phronomy::PoolShutdownError)
    end
  end

  # -------------------------------------------------------------------------
  # TC-008: operation_timeout — Timed-out operation is marked abandoned
  # -------------------------------------------------------------------------
  describe "TC-008: operation_timeout — timed-out operation is tracked as abandoned" do
    it "marks the PendingOperation as abandoned after TimeoutError" do
      op = pool.submit(timeout: 0.001) { sleep(1) }
      expect { op.await }.to raise_error(Phronomy::TimeoutError)
      expect(op).to be_abandoned
    end
  end

  # -------------------------------------------------------------------------
  # TC-009: stream_callback — SKIP (depends on Issue #292)
  # -------------------------------------------------------------------------
  describe "TC-009: stream_callback — stream callback does not run on pool worker thread" do
    it "is skipped pending Issue #292 (streaming callbacks via AsyncQueue)" do
      skip "Depends on Issue #292: streaming callback decoupling not yet implemented"
    end
  end
end
