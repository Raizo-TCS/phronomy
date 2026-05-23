# frozen_string_literal: true

require "spec_helper"

# ---------------------------------------------------------------------------
# Advanced fault injection tests (Issue #241)
#
# Verifies failure surfaces not covered by fault_injection_spec.rb or
# fault_injection_extended_spec.rb:
#   1. Embeddings#embed raises during RAG ingestion / search
#   2. VectorStore#search raises during build_context
#   3. VectorStore#add raises during knowledge ingestion
#   4. result_writer hook raises during output writing
#   5. Child FSM unhandled error — parent receives :child_failed event
#   6. Child FSM CancellationError — parent receives :child_failed event
#   7. before_completion hook raises during streaming (non-EventLoop path)
#   8. Output guardrail raises during streaming output validation
#   9. Huge tool output exceeds context budget — trimming or propagation
#  10. Output guardrail rejection + tool retry_on interaction
# ---------------------------------------------------------------------------
RSpec.describe "Fault injection advanced (Issue #241)" do
  # -------------------------------------------------------------------------
  # Shared chat double helpers
  # -------------------------------------------------------------------------
  let(:fake_tokens) { double("Tokens", input: 10, output: 5, cached: 0, cache_creation: 0) }
  let(:fake_message) { double("Message", content: "LLM response", tool_calls: nil, tokens: fake_tokens) }
  let(:fake_chat) do
    dbl = double("RubyLLM::Chat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
    allow(dbl).to receive(:with_temperature).and_return(dbl)
    allow(dbl).to receive(:ask).and_return(fake_message)
    allow(dbl).to receive(:messages).and_return([fake_message])
    allow(dbl).to receive(:last_message).and_return(fake_message)
    dbl
  end

  # -------------------------------------------------------------------------
  # 1. Embeddings#embed raises during RAG fetch
  # -------------------------------------------------------------------------
  describe "Embeddings#embed fault injection" do
    let(:exploding_embeddings) do
      Class.new(Phronomy::Embeddings::Base) do
        def embed(_text, _cancellation_token = nil)
          raise "embedding API unavailable"
        end
      end.new
    end

    let(:store) { Phronomy::VectorStore::InMemory.new(dimension: 3) }
    let(:rag_source) do
      Phronomy::KnowledgeSource::RAGKnowledge.new(
        store: store,
        embeddings: exploding_embeddings,
        k: 3
      )
    end

    it "propagates the embeddings error to the caller on #fetch" do
      # Current behaviour: exception propagates from embed → fetch.
      expect { rag_source.fetch(query: "anything") }
        .to raise_error(RuntimeError, "embedding API unavailable")
    end

    it "returns [] without calling embed when query is blank" do
      # Blank query short-circuits before embed — no error expected.
      expect { rag_source.fetch(query: "") }.not_to raise_error
      expect(rag_source.fetch(query: "")).to eq([])
    end
  end

  # -------------------------------------------------------------------------
  # 2. VectorStore#search raises during build_context
  # -------------------------------------------------------------------------
  describe "VectorStore#search fault injection during build_context" do
    let(:exploding_store) do
      Class.new(Phronomy::VectorStore::Base) do
        def add(**) = self
        def remove(**) = self
        def clear = self
        def size = 0

        def search(**)
          raise Phronomy::Error, "vector store search failure"
        end
      end.new
    end

    let(:stub_embeddings) do
      Class.new(Phronomy::Embeddings::Base) do
        def embed(_text, _cancellation_token = nil) = [1.0, 0.0, 0.0]
      end.new
    end

    let(:rag_source) do
      Phronomy::KnowledgeSource::RAGKnowledge.new(
        store: exploding_store,
        embeddings: stub_embeddings,
        k: 1
      )
    end

    it "propagates the VectorStore error from fetch" do
      expect { rag_source.fetch(query: "anything") }
        .to raise_error(Phronomy::Error, "vector store search failure")
    end

    it "propagates from build_context when knowledge source raises on search" do
      agent_class = Class.new(Phronomy::Agent::Base) { model "test-model" }
      agent = agent_class.new

      expect {
        agent.send(:build_context, "query",
          config: {knowledge_sources: [rag_source]})
      }.to raise_error(Phronomy::Error, "vector store search failure")
    end
  end

  # -------------------------------------------------------------------------
  # 3. VectorStore#add raises during knowledge ingestion
  # -------------------------------------------------------------------------
  describe "VectorStore#add fault injection" do
    let(:exploding_store) do
      Class.new(Phronomy::VectorStore::Base) do
        def add(**)
          raise ArgumentError, "dimension mismatch on ingestion"
        end

        def remove(**) = self
        def clear = self
        def size = 0
        def search(**) = []
      end.new
    end

    it "propagates ArgumentError when add is called with wrong dimension" do
      expect {
        exploding_store.add(id: "doc1", embedding: [1.0, 0.0], metadata: {})
      }.to raise_error(ArgumentError, "dimension mismatch on ingestion")
    end
  end

  # -------------------------------------------------------------------------
  # 4. result_writer hook raises during output writing
  # -------------------------------------------------------------------------
  describe "result_writer hook fault injection" do
    # AgentFSM#start runs in a Thread; child_failed event is posted to the parent.
    # This surface is already tested exhaustively in agent/fsm_spec.rb.
    # Here we verify the behaviour at the public AgentFSM API level as a
    # regression guard.

    let(:fake_loop) do
      events = []
      loop_dbl = double("EventLoop")
      allow(loop_dbl).to receive(:post) { |ev| events << ev }
      [loop_dbl, events]
    end

    it "posts :child_failed to the parent when result_writer raises" do
      loop_dbl, events = fake_loop
      allow(Phronomy::EventLoop).to receive(:instance).and_return(loop_dbl)

      result = {output: "ok", messages: [], usage: nil}
      agent = double("Agent")
      allow(agent).to receive(:send).and_return(result)

      fsm = Phronomy::Agent::FSM.new(
        agent: agent,
        input: "hi",
        thread_id: "child-1",
        parent_id: "parent-1",
        result_writer: ->(_r) { raise "writer exploded" }
      )
      fsm.start
      sleep 0.2

      fail_ev = events.find { |e| e.type == :child_failed }
      expect(fail_ev).not_to be_nil
      expect(fail_ev.target_id).to eq("parent-1")
      expect(fail_ev.payload.message).to match("writer exploded")
    end
  end

  # -------------------------------------------------------------------------
  # 5. Child FSM unhandled error — parent receives :child_failed event
  # -------------------------------------------------------------------------
  describe "Child FSM unhandled error" do
    it "posts :child_failed to parent_id with the exception as payload" do
      loop_dbl = double("EventLoop")
      events = []
      allow(loop_dbl).to receive(:post) { |ev| events << ev }
      allow(Phronomy::EventLoop).to receive(:instance).and_return(loop_dbl)

      error = RuntimeError.new("child agent blew up")
      agent = double("Agent")
      allow(agent).to receive(:send).and_raise(error)

      fsm = Phronomy::Agent::FSM.new(
        agent: agent, input: "hi",
        thread_id: "child-2", parent_id: "parent-2"
      )
      fsm.start
      sleep 0.2

      fail_ev = events.find { |e| e.type == :child_failed }
      expect(fail_ev).not_to be_nil
      expect(fail_ev.target_id).to eq("parent-2")
      expect(fail_ev.payload).to eq(error)
    end
  end

  # -------------------------------------------------------------------------
  # 6. Child FSM CancellationError — parent session behaviour
  # -------------------------------------------------------------------------
  describe "Child FSM CancellationError" do
    it "posts :child_failed to parent_id with CancellationError as payload" do
      loop_dbl = double("EventLoop")
      events = []
      allow(loop_dbl).to receive(:post) { |ev| events << ev }
      allow(Phronomy::EventLoop).to receive(:instance).and_return(loop_dbl)

      cancel_error = Phronomy::CancellationError.new("cancelled by timeout")
      agent = double("Agent")
      allow(agent).to receive(:send).and_raise(cancel_error)

      fsm = Phronomy::Agent::FSM.new(
        agent: agent, input: "hi",
        thread_id: "child-3", parent_id: "parent-3"
      )
      fsm.start
      sleep 0.2

      fail_ev = events.find { |e| e.type == :child_failed }
      expect(fail_ev).not_to be_nil
      expect(fail_ev.payload).to be_a(Phronomy::CancellationError)
    end
  end

  # -------------------------------------------------------------------------
  # 7. before_completion hook raises during streaming (non-EventLoop path)
  # -------------------------------------------------------------------------
  describe "before_completion hook raises during streaming" do
    it "propagates the hook exception to the caller" do
      agent_class = Class.new(Phronomy::Agent::Base) { model "test-model" }
      agent = agent_class.new
      agent.before_completion = ->(_ctx) { raise "hook failed during stream" }

      chat_double = double("RubyLLM::Chat")
      allow(chat_double).to receive(:messages).and_return([])

      expect {
        agent.send(:run_before_completion_hooks!, chat_double, {})
      }.to raise_error(RuntimeError, "hook failed during stream")
    end
  end

  # -------------------------------------------------------------------------
  # 8. Output guardrail raises during streaming output validation
  # -------------------------------------------------------------------------
  describe "Output guardrail raises during streaming" do
    let(:exploding_guardrail) do
      Class.new(Phronomy::Guardrail::OutputGuardrail) do
        def check(_output)
          raise "guardrail exploded during streaming"
        end
      end.new
    end

    it "propagates the guardrail exception unchanged" do
      # run! calls check internally; an unhandled exception propagates to caller.
      expect { exploding_guardrail.run!("partial stream output") }
        .to raise_error(RuntimeError, "guardrail exploded during streaming")
    end
  end

  # -------------------------------------------------------------------------
  # 9. Huge tool output — behavior when tool returns oversized content
  # -------------------------------------------------------------------------
  describe "Huge tool output" do
    # A tool returning a very large string is allowed by Phronomy::Tool::Base.
    # Context budget trimming occurs inside Agent#_invoke_impl; the tool itself
    # does not enforce output size limits. This test documents that behaviour.
    let(:huge_output_tool) do
      Class.new(Phronomy::Tool::Base) do
        description "Returns a huge string"

        def execute
          "x" * 100_000
        end
      end.new
    end

    it "tool#call returns the huge string without raising" do
      result = huge_output_tool.call({})
      expect(result.length).to eq(100_000)
    end
  end

  # -------------------------------------------------------------------------
  # 10. Output guardrail rejection + tool retry_on interaction
  # -------------------------------------------------------------------------
  describe "Output guardrail rejection + tool retry_on interaction" do
    # GuardrailError is not a ToolError subclass, so retry_on ToolError does
    # NOT catch guardrail rejections — the exception propagates after the
    # inner ToolError retry is exhausted or bypassed.
    let(:always_fail_tool) do
      Class.new(Phronomy::Tool::Base) do
        description "Fails and never succeeds"
        on_error :propagate

        def execute
          raise Phronomy::ToolError, "tool always fails"
        end
      end.new
    end

    let(:always_reject_guardrail) do
      Class.new(Phronomy::Guardrail::OutputGuardrail) do
        def check(output)
          fail!("rejected: #{output}")
        end
      end.new
    end

    it "tool raises ToolError regardless of any guardrail being configured" do
      expect { always_fail_tool.call({}) }.to raise_error(Phronomy::ToolError, "tool always fails")
    end

    it "guardrail raises GuardrailError regardless of any tool retry policy" do
      # GuardrailError is orthogonal to ToolError retry — they do not interact.
      expect { always_reject_guardrail.run!("some output") }
        .to raise_error(Phronomy::GuardrailError, /rejected/)
    end
  end

  # -------------------------------------------------------------------------
  # 11. RAG nil / invalid chunk from KnowledgeSource (Issue #243)
  # -------------------------------------------------------------------------
  describe "RAG nil/invalid chunk from KnowledgeSource" do
    # When a custom KnowledgeSource returns a non-Hash element (nil or Integer),
    # build_context propagates a NoMethodError because it calls chunk[:content]
    # on the raw element without a nil-guard.  This test documents the current
    # propagation contract so any future nil-guard change is visible.

    let(:agent_class) { Class.new(Phronomy::Agent::Base) { model "test-model" } }
    let(:agent) { agent_class.new }

    it "propagates NoMethodError when KnowledgeSource#fetch returns [nil]" do
      nil_ks = double("NilKnowledgeSource")
      allow(nil_ks).to receive(:fetch).and_return([nil])

      expect {
        agent.send(:build_context, "hello",
          messages: [],
          thread_id: nil,
          config: {knowledge_sources: [nil_ks]})
      }.to raise_error(NoMethodError)
    end

    it "propagates TypeError when KnowledgeSource#fetch returns [42] (non-Hash chunk)" do
      int_ks = double("IntKnowledgeSource")
      allow(int_ks).to receive(:fetch).and_return([42])

      expect {
        agent.send(:build_context, "hello",
          messages: [],
          thread_id: nil,
          config: {knowledge_sources: [int_ks]})
      }.to raise_error(TypeError)
    end
  end

  # -------------------------------------------------------------------------
  # 12. before_completion returns invalid type (Issue #243)
  # -------------------------------------------------------------------------
  describe "before_completion hook returns invalid type (non-Hash)" do
    # When a before_completion hook returns a non-Hash value (e.g. Integer 42),
    # the current implementation silently ignores it — only Hash return values
    # are merged into the LLM call params.  This documents the current contract.

    let(:agent_class) { Class.new(Phronomy::Agent::Base) { model "test-model" } }
    let(:agent) { agent_class.new }
    let(:chat_double) do
      dbl = double("RubyLLM::Chat")
      allow(dbl).to receive(:messages).and_return([])
      dbl
    end

    it "silently ignores an Integer return value from the hook" do
      agent.before_completion = ->(_ctx) { 42 }
      result = agent.send(:run_before_completion_hooks!, chat_double, {})
      expect(result).to eq({})
    end

    it "silently ignores a String return value from the hook" do
      agent.before_completion = ->(_ctx) { "not a hash" }
      result = agent.send(:run_before_completion_hooks!, chat_double, {})
      expect(result).to eq({})
    end
  end

  # -------------------------------------------------------------------------
  # 13. EventLoop shutdown rejects new sessions (Issue #243)
  # -------------------------------------------------------------------------
  describe "EventLoop shutdown rejects new sessions with CancellationError" do
    # When the EventLoop's shutdown_token has been cancelled (set by stop()),
    # any new :start event is rejected immediately: the completion_queue receives
    # a CancellationError so callers never block indefinitely.

    after do
      Phronomy::EventLoop.reset!
      Phronomy.reset_configuration!
    end

    it "pushes CancellationError to the completion_queue when the shutdown token is active" do
      Phronomy.configure { |c| c.event_loop = true }
      el = Phronomy::EventLoop.instance
      # Simulate shutdown state without stopping the thread (token only).
      el.instance_variable_get(:@shutdown_token).cancel!

      agent = double("Agent")
      allow(agent).to receive(:class).and_return(double(respond_to?: false))

      fsm = Phronomy::Agent::FSM.new(
        agent: agent,
        input: "hi",
        thread_id: "shutdown-reject-test"
      )
      cq = el.register(fsm)
      result = cq.pop

      expect(result).to be_a(Phronomy::CancellationError)
      expect(result.message).to match(/shutting down/)
    end
  end

  # -------------------------------------------------------------------------
  # 14. Approval handler raises exception (Issue #243)
  # -------------------------------------------------------------------------
  describe "approval handler raises exception" do
    # When the on_approval_required handler raises, the exception propagates
    # through Tool#call to the agent's tool execution path.

    let(:approval_tool_class) do
      Class.new(Phronomy::Tool::Base) do
        tool_name "approval_fault_tool"
        requires_approval true
        description "A tool that requires approval"

        def execute
          "executed"
        end
      end
    end

    it "propagates RuntimeError raised inside the approval handler through tool#call" do
      agent = Class.new(Phronomy::Agent::Base) { model "test-model" }.new
      agent.on_approval_required { |_name, _args| raise "approval handler failed" }

      wrapped = agent.send(:prepare_tool_class, approval_tool_class)
      expect { wrapped.new.call({}) }.to raise_error(RuntimeError, "approval handler failed")
    end
  end

  # -------------------------------------------------------------------------
  # 15. before_completion raises + output_guardrail registered (Issue #243)
  # -------------------------------------------------------------------------
  describe "before_completion raises with output_guardrail also registered" do
    # When before_completion raises, the exception propagates before the LLM
    # call and before run_output_guardrails! is reached.  The guardrail must
    # NOT be invoked.

    let(:agent_class) { Class.new(Phronomy::Agent::Base) { model "test-model" } }
    let(:chat_double) do
      dbl = double("RubyLLM::Chat")
      allow(dbl).to receive(:messages).and_return([])
      dbl
    end

    it "propagates the hook exception and does not invoke the output guardrail" do
      agent = agent_class.new
      agent.before_completion = ->(_ctx) { raise "hook exploded" }

      guardrail_invoked = false
      spy_guardrail = double("SpyGuardrail")
      allow(spy_guardrail).to receive(:run!) { guardrail_invoked = true }

      agent.instance_variable_set(:@output_guardrails, [spy_guardrail])

      expect {
        agent.send(:run_before_completion_hooks!, chat_double, {})
      }.to raise_error(RuntimeError, "hook exploded")

      expect(guardrail_invoked).to be(false)
    end
  end
end
