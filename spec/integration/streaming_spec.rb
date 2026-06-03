# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Group 9: Agent Token-Level Streaming
# Pairwise factors: agent_class × agent_streaming_mode × stream_event_types_expected
#                   × stream_guardrail_interaction × agent_tools
# Generated stubs: 20 cases
#
# Infeasible cases (skipped):
#   TC-002: no_block × tool_call_and_result — no_block falls back to invoke; no events emitted
#   TC-004: done_only × with_block — LM Studio streams partial tokens; cannot guarantee zero :token events
#   TC-007: Base + no_block × error — no_block does not emit events; cannot observe :error
#   TC-009: Base + no_block + blocking_input — blocking_input raises before any event;
#           no_block path does not capture events either
#   TC-018/TC-019/TC-020: done_only — same reason as TC-004; LM Studio always streams tokens
#
# Verified feasible cases: TC-001, TC-002 (fallback), TC-003, TC-006, TC-007 (fallback), TC-008,
#                           TC-010 (fallback), TC-011 (fallback), TC-012, TC-013

LM_MODEL_9 = IntegrationFactors::LM_STUDIO_MODEL

# Build a streaming-capable agent class
def build_streaming_agent(klass_label:, tools: [], instructions: "You are a helpful assistant.")
  base = Phronomy::Agent::Base
  tool_arg = tools

  Class.new(base) do
    model LM_MODEL_9
    provider :openai
    self.instructions(instructions)
    case tool_arg
    when Hash then self.tools(tool_arg)
    when Array then self.tools(*tool_arg) unless tool_arg.empty?
    end
  end
end

RSpec.describe "Group 9: Agent Token-Level Streaming", :integration do
  # Streaming SSE format is complex to stub with WebMock.
  # All tests in this group are skipped until a streaming stub is implemented.
  before { skip("streaming stub not implemented") }

  # ---------------------------------------------------------------------------
  # TC-001: Base + with_block + none guardrail + no tools
  #         Expect: at least one :done event; output non-empty
  # ---------------------------------------------------------------------------
  describe "TC-001: Base + with_block + no guardrails + no tools — baseline :done event" do
    it "emits a :done event with non-empty output" do
      klass = build_streaming_agent(klass_label: "base")
      events = []
      result = klass.new.stream("Reply with exactly one word: hello.") { |e| events << e }

      done_events = events.select { |e| e.type == :done }
      expect(done_events.size).to eq(1)
      expect(done_events.first.payload[:output]).to be_a(String)
      expect(done_events.first.payload[:output]).not_to be_empty

      expect(result[:output]).to eq(done_events.first.payload[:output])
    end

    it "return value matches :done payload output" do
      klass = build_streaming_agent(klass_label: "base")
      done_payload = nil
      result = klass.new.stream("Say the word yes.") { |e| done_payload = e.payload if e.type == :done }
      expect(result[:output]).to eq(done_payload[:output])
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: Base + no_block — fallback to invoke; no events emitted
  # ---------------------------------------------------------------------------
  describe "TC-002: Base + no_block — falls back to #invoke" do
    it "returns a Hash with :output when no block is given" do
      klass = build_streaming_agent(klass_label: "base")
      result = klass.new.stream("Say the word yes.")
      expect(result).to include(:output, :messages, :usage)
      expect(result[:output]).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-003: Base + with_block + blocking_input guardrail
  #         Expect: :error event emitted, then GuardrailError raised
  # ---------------------------------------------------------------------------
  describe "TC-003: Base + with_block + blocking_input guardrail — :error event then raises" do
    it "emits an :error event before raising GuardrailError" do
      klass = build_streaming_agent(klass_label: "base")
      agent = klass.new
      agent.add_input_guardrail(IntegrationFactors::BlockingInputGuardrail.new)

      events = []
      expect {
        agent.stream("hello") { |e| events << e }
      }.to raise_error(Phronomy::GuardrailError)

      expect(events.map(&:type)).to include(:error)
      error_event = events.find { |e| e.type == :error }
      expect(error_event.payload[:error]).to be_a(Phronomy::GuardrailError)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: Base + with_block + passing_input + single_tool
  #         Expect: :done event with non-empty output
  # ---------------------------------------------------------------------------
  describe "TC-006: Base + with_block + passing_input + single_tool — :done event" do
    it "emits a :done event and returns output" do
      klass = build_streaming_agent(
        klass_label: "base",
        tools: [IntegrationFactors::CalculatorTool],
        instructions: "You are a calculator assistant. Use the calculator tool to answer math questions."
      )
      agent = klass.new
      agent.add_input_guardrail(IntegrationFactors::PassingInputGuardrail.new)

      events = []
      result = agent.stream("What is 9 + 6?") { |e| events << e }

      done_events = events.select { |e| e.type == :done }
      expect(done_events.size).to eq(1)
      expect(result[:output]).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-007: Base + no_block — fallback to invoke; no events
  # ---------------------------------------------------------------------------
  describe "TC-007: Base + no_block — falls back to #invoke" do
    it "returns a Hash with :output" do
      klass = build_streaming_agent(klass_label: "base")
      result = klass.new.stream("Say the word yes.")
      expect(result).to include(:output, :messages, :usage)
      expect(result[:output]).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-008: Base + with_block + blocking_input
  #         Expect: :error event + GuardrailError
  # ---------------------------------------------------------------------------
  describe "TC-008: Base + with_block + blocking_input — :error event then raises" do
    it "emits :error event and raises GuardrailError" do
      klass = build_streaming_agent(klass_label: "base")
      agent = klass.new
      agent.add_input_guardrail(IntegrationFactors::BlockingInputGuardrail.new)

      events = []
      expect {
        agent.stream("hello") { |e| events << e }
      }.to raise_error(Phronomy::GuardrailError)

      expect(events.map(&:type)).to include(:error)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-010: Base + no_block + no guardrail + multi tools — fallback
  # ---------------------------------------------------------------------------
  describe "TC-010: Base + no_block + multi tools — invoke fallback" do
    it "returns a Hash with :output" do
      klass = build_streaming_agent(
        klass_label: "base",
        tools: [IntegrationFactors::CalculatorTool, IntegrationFactors::WeatherTool]
      )
      result = klass.new.stream("Say the word yes.")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-011: Base + no_block + passing_input + no tools — fallback
  # TC-011 is infeasible (no_block × error event_type). We test the fallback path only.
  # ---------------------------------------------------------------------------
  describe "TC-011: Base + no_block + passing_input + no tools — invoke fallback" do
    it "returns a Hash (invoke fallback)" do
      klass = build_streaming_agent(klass_label: "base")
      agent = klass.new
      agent.add_input_guardrail(IntegrationFactors::PassingInputGuardrail.new)
      result = agent.stream("Say the word yes.")
      expect(result[:output]).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-012: Base + with_block + blocking_input + hash_alias tool
  #         Expect: :error event + GuardrailError (tool irrelevant — blocked before LLM)
  # ---------------------------------------------------------------------------
  describe "TC-012: Base + with_block + blocking_input + hash_alias tool — :error event" do
    it "emits :error before LLM is called regardless of tool config" do
      klass = build_streaming_agent(
        klass_label: "base",
        tools: {IntegrationFactors::CalculatorTool => "calc"}
      )
      agent = klass.new
      agent.add_input_guardrail(IntegrationFactors::BlockingInputGuardrail.new)

      events = []
      expect {
        agent.stream("hello") { |e| events << e }
      }.to raise_error(Phronomy::GuardrailError)

      expect(events.map(&:type)).to include(:error)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-013: Base + with_block + passing_input + hash_no_alias tool
  #         Expect: :done event, output non-empty
  # ---------------------------------------------------------------------------
  describe "TC-013: Base + with_block + passing_input + hash_no_alias tool — :done event" do
    it "emits :done with non-empty output" do
      klass = build_streaming_agent(
        klass_label: "base",
        tools: {IntegrationFactors::CalculatorTool => nil}
      )
      agent = klass.new
      agent.add_input_guardrail(IntegrationFactors::PassingInputGuardrail.new)

      events = []
      agent.stream("Say the word yes.") { |e| events << e }

      expect(events.map(&:type)).to include(:done)
      expect(events.find { |e| e.type == :done }.payload[:output]).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-016 / TC-017 combined: :token events structure validation
  # Base + with_block, no guardrail, single tool — at least token or done
  # ---------------------------------------------------------------------------
  describe "TC-016/TC-017: :token events have String :content payload" do
    it "every :token event has a String or nil content payload" do
      klass = build_streaming_agent(klass_label: "base")
      events = []
      klass.new.stream("Say one short word.") { |e| events << e }

      token_events = events.select { |e| e.type == :token }
      token_events.each do |ev|
        expect(ev.payload[:content]).to be_a(String).or be_nil
      end
      # At least :done must be present even if no :token events arrive
      expect(events.map(&:type)).to include(:done)
    end
  end
end
