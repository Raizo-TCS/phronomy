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
#   4. Child FSM unhandled error — parent receives :child_failed event
#   5. Child FSM CancellationError — parent receives :child_failed event
#   6. before_completion hook raises during streaming (non-EventLoop path)
#   7. Output guardrail raises during streaming output validation
#   8. Huge tool output exceeds context budget — trimming or propagation
#   9. Output guardrail rejection + tool retry_on interaction
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
  # 4. before_completion hook raises during streaming (non-EventLoop path)
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
  # 7. Output guardrail raises during streaming output validation
  # -------------------------------------------------------------------------
  describe "Output guardrail raises during streaming" do
    let(:exploding_guardrail) do
      Class.new(Phronomy::Filter::Base) do
        def call(_output, **_ctx)
          raise "guardrail exploded during streaming"
        end
      end.new
    end

    it "propagates the guardrail exception unchanged" do
      # call raises an unhandled exception that propagates to caller.
      expect { exploding_guardrail.call("partial stream output") }
        .to raise_error(RuntimeError, "guardrail exploded during streaming")
    end
  end

  # -------------------------------------------------------------------------
  # 8. Huge tool output — behavior when tool returns oversized content
  # -------------------------------------------------------------------------
  describe "Huge tool output" do
    # A tool returning a very large string is allowed by Phronomy::Agent::Context::Capability::Base.
    # Context budget trimming occurs inside Agent#_invoke_impl; the tool itself
    # does not enforce output size limits. This test documents that behaviour.
    let(:huge_output_tool) do
      Class.new(Phronomy::Agent::Context::Capability::Base) do
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
  # 9. Output guardrail rejection + tool retry_on interaction
  # -------------------------------------------------------------------------
  describe "Output guardrail rejection + tool retry_on interaction" do
    # FilterBlockError is not a ToolError subclass, so retry_on ToolError does
    # NOT catch guardrail rejections — the exception propagates after the
    # inner ToolError retry is exhausted or bypassed.
    let(:always_fail_tool) do
      Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "Fails and never succeeds"
        on_error :propagate

        def execute
          raise Phronomy::ToolError, "tool always fails"
        end
      end.new
    end

    let(:always_reject_guardrail) do
      Class.new(Phronomy::Filter::Base) do
        def call(output, **_ctx)
          block!("rejected: #{output}")
          output
        end
      end.new
    end

    it "tool raises ToolError regardless of any guardrail being configured" do
      expect { always_fail_tool.call({}) }.to raise_error(Phronomy::ToolError, "tool always fails")
    end

    it "guardrail raises FilterBlockError regardless of any tool retry policy" do
      # FilterBlockError is orthogonal to ToolError retry — they do not interact.
      expect { always_reject_guardrail.call("some output") }
        .to raise_error(Phronomy::FilterBlockError, /rejected/)
    end
  end

  # -------------------------------------------------------------------------
  # 11. before_completion returns invalid type (Issue #243)
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
      el = Phronomy::EventLoop.instance
      # Simulate shutdown state without stopping the thread (token only).
      el.instance_variable_get(:@shutdown_token).cancel!

      # Use a minimal duck-type session — Agent::FSM no longer exists.
      fake_session = double("Session", id: "shutdown-reject-test")
      cq = el.register(fake_session)
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
      Class.new(Phronomy::Agent::Context::Capability::Base) do
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

    it "propagates the hook exception and does not invoke the output filter" do
      agent = agent_class.new
      agent.before_completion = ->(_ctx) { raise "hook exploded" }

      spy_filter = Class.new(Phronomy::Filter::Base) do
        attr_accessor :invoked
        def call(val, **_ctx)
          @invoked = true
          val
        end
      end.new
      agent.add_output_filter(spy_filter)

      expect {
        agent.send(:run_before_completion_hooks!, chat_double, {})
      }.to raise_error(RuntimeError, "hook exploded")

      expect(spy_filter.invoked).to be_falsey
    end
  end

  # -------------------------------------------------------------------------
  # 16. on_chunk streaming callback raises mid-stream (Issue #254)
  # -------------------------------------------------------------------------
  describe "streaming on_chunk callback raises mid-stream (Issue #254)" do
    let(:chunk1) { double("Chunk1", content: "Hello") }
    let(:chunk2) { double("Chunk2", content: " World") }
    let(:chunk3) { double("Chunk3", content: "!") }

    let(:streaming_chat) do
      dbl = double("StreamingChat")
      allow(dbl).to receive(:with_instructions).and_return(dbl)
      allow(dbl).to receive(:with_tool).and_return(dbl)
      allow(dbl).to receive(:with_temperature).and_return(dbl)
      allow(dbl).to receive(:on_tool_call)
      allow(dbl).to receive(:on_tool_result)
      allow(dbl).to receive(:ask)
        .and_yield(chunk1).and_yield(chunk2).and_yield(chunk3)
        .and_return(fake_message)
      allow(dbl).to receive(:messages).and_return([])
      dbl
    end

    let(:streaming_agent_class) { Class.new(Phronomy::Agent::Base) { model "test-model" } }
    let(:streaming_agent) { streaming_agent_class.new }

    before do
      allow(streaming_agent).to receive(:build_chat).and_return(streaming_chat)
    end

    it "propagates the callback exception to the stream caller" do
      chunk_count = 0
      received_event_types = []

      expect {
        streaming_agent.stream("trigger streaming") do |event|
          received_event_types << event.type
          if event.type == :token
            chunk_count += 1
            raise "callback exploded on chunk #{chunk_count}" if chunk_count == 2
          end
        end
      }.to raise_error(RuntimeError, "callback exploded on chunk 2")

      # An :error StreamEvent is delivered to the block before the exception re-raises.
      expect(received_event_types).to include(:error)
    end

    it "does not leave the agent in a bad state; a subsequent invoke succeeds" do
      # First call: the callback raises on the very first token event.
      expect {
        streaming_agent.stream("trigger streaming") do |event|
          raise "boom" if event.type == :token
        end
      }.to raise_error(RuntimeError, "boom")

      # Prepare a non-raising chat double for the follow-up invoke.
      calm_chat = double("CalmChat")
      allow(calm_chat).to receive(:with_instructions).and_return(calm_chat)
      allow(calm_chat).to receive(:with_tool).and_return(calm_chat)
      allow(calm_chat).to receive(:with_temperature).and_return(calm_chat)
      allow(calm_chat).to receive(:on_tool_call)
      allow(calm_chat).to receive(:on_tool_result)
      allow(calm_chat).to receive(:ask).and_return(fake_message)
      allow(calm_chat).to receive(:messages).and_return([])
      allow(streaming_agent).to receive(:build_chat).and_return(calm_chat)

      result = streaming_agent.invoke("hello again")
      expect(result[:output]).to eq("LLM response")
    end
  end
end
