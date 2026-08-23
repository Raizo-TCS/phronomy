# frozen_string_literal: true

require "spec_helper"

# Advanced fault-injection coverage for failure surfaces not exercised by the
# primary fault_injection specs. Context-specific behavior in this file is
# expressed through the current before_llm_input / Manifest-first contracts;
# the removed build_context path is not part of this suite.
#
# ACS-18 failure-model mapping:
#
# - VectorStore/hook/filter/callback failures are F0 Operation Failure cases.
# - "Tool failure is not replayed by Phronomy" is F0 evidence at an X0-capable
#   integration boundary. The test guards against blind framework replay; it
#   does NOT establish duplicate prevention or exactly-once external effects.
# - orderly EventLoop :stopping rejection is lifecycle-shutdown evidence, not
#   F4 Execution-Environment Loss recovery coverage.
# - F1 Outcome Uncertainty is deliberately not inferred from any exception in
#   this file.
#
# See ADR-018 for the canonical failure and guarantee vocabulary.
RSpec.describe "Fault injection advanced (Issue #241)" do
  let(:fake_tokens) do
    double(
      "Tokens",
      input: 10,
      output: 5,
      cached: 0,
      cache_creation: 0,
      to_h: {"input" => 10, "output" => 5, "cached" => 0, "cache_creation" => 0}
    )
  end
  let(:fake_message) do
    double("Message", content: "LLM response", tool_calls: nil, tokens: fake_tokens)
  end

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

  describe "before_llm_input hook raises during execution" do
    it "propagates the hook exception to the caller" do
      agent_class = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-102", version: 1
        model "test-model"
      end
      agent = agent_class.new
      agent.before_llm_input = ->(_ctx) { raise "hook failed" }

      expect {
        agent.send(:run_before_llm_input_hooks, call_sequence: 1, config: {})
      }.to raise_error(RuntimeError, "hook failed")
    end
  end

  describe "Output filter raises during streaming" do
    let(:exploding_filter) do
      Class.new(Phronomy::Filter::Base) do
        def call(_output, **_ctx)
          raise "filter exploded during streaming"
        end
      end.new
    end

    it "propagates the filter exception unchanged" do
      expect { exploding_filter.call("partial stream output") }
        .to raise_error(RuntimeError, "filter exploded during streaming")
    end
  end

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
      filter = Class.new(Phronomy::Filter::Base) do
        def call(output, **_ctx)
          block!("rejected: #{output}")
        end
      end.new

      expect { filter.call("some output") }
        .to raise_error(Phronomy::FilterBlockError, /rejected/)
    end
  end

  describe "before_llm_input hook returns invalid type (non-LLMInputPatch)" do
    let(:agent_class) do
      Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-301", version: 1
        model "test-model"
      end
    end
    let(:agent) { agent_class.new }

    it "raises TypeError for an Integer return value from the hook" do
      agent.before_llm_input = ->(_ctx) { 42 }
      expect {
        agent.send(:run_before_llm_input_hooks, call_sequence: 1, config: {})
      }.to raise_error(TypeError, /LLMInputPatch/)
    end

    it "raises TypeError for a String return value from the hook" do
      agent.before_llm_input = ->(_ctx) { "not a patch" }
      expect {
        agent.send(:run_before_llm_input_hooks, call_sequence: 1, config: {})
      }.to raise_error(TypeError, /LLMInputPatch/)
    end
  end

  describe "EventLoop shutdown rejects new sessions with RuntimeShutdownError" do
    it "raises RuntimeShutdownError when the EventLoop state is :stopping" do
      runtime = Phronomy::Runtime.new
      event_loop = runtime.event_loop

      event_loop.instance_variable_get(:@lifecycle_mutex).synchronize do
        event_loop.instance_variable_set(:@state, :stopping)
      end

      fake_session = double("Session", id: "shutdown-reject-test")
      expect { event_loop.register(fake_session) }
        .to raise_error(Phronomy::RuntimeShutdownError)
    ensure
      begin
        runtime.shutdown(timeout: 1)
      rescue
        nil
      end
    end
  end

  describe "approval policy raises exception" do
    it "registers tool_approval_policy that raises without error at registration" do
      agent = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-204", version: 1
        model "test-model"
      end.new

      expect {
        agent.tool_approval_policy { |_req| raise "approval policy failed" }
      }.not_to raise_error
    end
  end

  describe "before_llm_input raises with output_filter also registered" do
    let(:agent_class) do
      Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-302", version: 1
        model "test-model"
      end
    end

    it "propagates the hook exception and does not invoke the output filter" do
      agent = agent_class.new
      agent.before_llm_input = ->(_ctx) { raise "hook exploded" }

      spy_filter = Class.new(Phronomy::Filter::Base) do
        attr_accessor :invoked

        def call(val, **_ctx)
          @invoked = true
          val
        end
      end.new
      agent.add_output_filter(spy_filter)

      expect {
        agent.send(:run_before_llm_input_hooks, call_sequence: 1, config: {})
      }.to raise_error(RuntimeError, "hook exploded")

      expect(spy_filter.invoked).to be_falsey
    end
  end

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
      allow(dbl).to receive(:before_tool_call)
      allow(dbl).to receive(:on_tool_result)
      allow(dbl).to receive(:ask)
        .and_yield(chunk1).and_yield(chunk2).and_yield(chunk3)
        .and_return(fake_message)
      allow(dbl).to receive(:messages).and_return([])
      dbl
    end

    let(:streaming_agent_class) do
      Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-303", version: 1
        model "test-model"
      end
    end
    let(:streaming_agent) { streaming_agent_class.new }

    before do
      allow(streaming_agent).to receive(:build_chat).and_return(streaming_chat)
    end

    it "propagates the callback exception to the stream caller" do
      chunk_count = 0

      expect {
        streaming_agent.stream("trigger streaming") do |event|
          if event.type == :token
            chunk_count += 1
            raise "callback exploded on chunk #{chunk_count}" if chunk_count == 2
          end
        end
      }.to raise_error(Phronomy::StreamCallbackError) { |error|
        expect(error.event_type).to eq(:token)
        expect(error.original_error.message).to eq("callback exploded on chunk 2")
      }
    end

    it "does not leave the agent in a bad state; a subsequent invoke succeeds" do
      expect {
        streaming_agent.stream("trigger streaming") do |event|
          raise "boom" if event.type == :token
        end
      }.to raise_error(Phronomy::StreamCallbackError)

      calm_chat = double("CalmChat")
      calm_tokens = double(
        "CalmTokens",
        input: 1,
        output: 1,
        cached: 0,
        cache_creation: 0,
        to_h: {"input" => 1, "output" => 1, "cached" => 0, "cache_creation" => 0}
      )
      calm_message = double(
        "CalmMessage",
        content: "ok",
        tool_calls: nil,
        tokens: calm_tokens,
        tool_call?: false,
        role: :assistant
      )
      allow(calm_chat).to receive(:with_instructions).and_return(calm_chat)
      allow(calm_chat).to receive(:with_tool).and_return(calm_chat)
      allow(calm_chat).to receive(:with_temperature).and_return(calm_chat)
      allow(calm_chat).to receive(:on_tool_call)
      allow(calm_chat).to receive(:before_tool_call)
      allow(calm_chat).to receive(:on_tool_result)
      allow(calm_chat).to receive(:ask).and_return(calm_message)
      allow(calm_chat).to receive(:messages).and_return([])
      allow(streaming_agent).to receive(:build_chat).and_return(calm_chat)

      result = streaming_agent.invoke("hello again")
      expect(result[:output]).to eq("ok")
    end
  end
end
