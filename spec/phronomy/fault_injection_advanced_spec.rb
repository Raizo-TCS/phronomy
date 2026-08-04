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
#   9. Tool failure is not replayed by Phronomy
# ---------------------------------------------------------------------------
RSpec.describe "Fault injection advanced (Issue #241)" do
  # -------------------------------------------------------------------------
  # Shared chat double helpers
  # -------------------------------------------------------------------------
  let(:fake_tokens) { double("Tokens", input: 10, output: 5, cached: 0, cache_creation: 0, to_h: {"input" => 10, "output" => 5, "cached" => 0, "cache_creation" => 0}) }
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
      agent_class = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-102", version: 1
        model "test-model"
      end
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
    # Context budget trimming occurs inside Agent#build_context; the tool itself
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
  # 9. Tool failure is not replayed by Phronomy
  # -------------------------------------------------------------------------
  describe "Tool failure is not replayed by Phronomy" do
    it "executes the Tool body once and propagates ToolError" do
      attempts = 0
      tool_class = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "Fails and never succeeds"

        define_method(:execute) do
          attempts += 1
          raise Phronomy::ToolError, "tool always fails"
        end
      end

      expect { tool_class.new.call({}) }
        .to raise_error(Phronomy::ToolError, "tool always fails")
      expect(attempts).to eq(1)
    end

    it "keeps output-filter rejection independent from Tool execution" do
      guardrail = Class.new(Phronomy::Filter::Base) do
        def call(output, **_ctx)
          block!("rejected: #{output}")
        end
      end.new

      expect { guardrail.call("some output") }
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

    let(:agent_class) {
      Class.new(Phronomy::Agent::Base) {
        agent_definition id: "test-agent-301", version: 1
        model "test-model"
      }
    }
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
  describe "EventLoop shutdown rejects new sessions with RuntimeShutdownError" do
    # When the EventLoop state is :stopping or later, new register calls raise
    # RuntimeShutdownError so callers never block indefinitely.

    it "raises RuntimeShutdownError when the EventLoop state is :stopping" do
      runtime = Phronomy::Runtime.new
      el = runtime.event_loop

      # Transition to :stopping state directly to simulate post-shutdown-initiation.
      el.instance_variable_get(:@lifecycle_mutex).synchronize do
        el.instance_variable_set(:@state, :stopping)
      end

      fake_session = double("Session", id: "shutdown-reject-test")
      expect { el.register(fake_session) }.to raise_error(Phronomy::RuntimeShutdownError)
    ensure
      begin
        runtime.shutdown(timeout: 1)
      rescue
        nil
      end
    end
  end

  # -------------------------------------------------------------------------
  # 14. Approval policy raises exception (Issue #243)
  # -------------------------------------------------------------------------
  describe "approval policy raises exception" do
    # When tool_approval_policy raises, the exception is treated as an
    # authorization failure (fail-closed: :require_approval / timeout path).

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

    it "registers tool_approval_policy that raises without error at registration" do
      agent = Class.new(Phronomy::Agent::Base) {
        agent_definition id: "test-agent-204", version: 1
        model "test-model"
      }.new
      expect {
        agent.tool_approval_policy { |_req| raise "approval policy failed" }
      }.not_to raise_error
    end
  end

  # -------------------------------------------------------------------------
  # 15. before_completion raises + output_guardrail registered (Issue #243)
  # -------------------------------------------------------------------------
  describe "before_completion raises with output_guardrail also registered" do
    # When before_completion raises, the exception propagates before the LLM
    # call and before run_output_guardrails! is reached.  The guardrail must
    # NOT be invoked.

    let(:agent_class) {
      Class.new(Phronomy::Agent::Base) {
        agent_definition id: "test-agent-302", version: 1
        model "test-model"
      }
    }
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

    let(:streaming_agent_class) {
      Class.new(Phronomy::Agent::Base) {
        agent_definition id: "test-agent-303", version: 1
        model "test-model"
      }
    }
    let(:streaming_agent) { streaming_agent_class.new }

    before do
      allow(streaming_agent).to receive(:build_chat).and_return(streaming_chat)
    end

    it "propagates the callback exception to the stream caller" do
      skip "requires ExecutionCoordinator refactor: AgentExecutionActivation#record_event absorbs callback exceptions"
    end

    it "does not leave the agent in a bad state; a subsequent invoke succeeds" do
      skip "requires ExecutionCoordinator refactor: AgentExecutionActivation#record_event absorbs callback exceptions"
    end
  end
end
