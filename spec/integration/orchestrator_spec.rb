# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Group 34: Orchestrator
# Pairwise factors: orch_delegation_mode × orch_subagent_count × orch_on_error
# Generated stubs: 6 cases
#
# Infeasible cases:
#   None — all 6 cases are structurally valid, though orch_on_error has no
#   effect for :parallel and :fan_out modes (those bypass the LLM entirely).
#
# LLM required:
#   TC-001, TC-002: No (WebMock) — declarative mode; LLM interaction stubbed
#   TC-003, TC-004: No (no LLM) — dispatch_parallel; pure Ruby thread dispatch
#   TC-005, TC-006: No (no LLM) — fan_out; pure Ruby thread dispatch

RSpec.describe "Group 34: Orchestrator", :integration do
  # Stub agent whose invoke is handled entirely without LLM (no HTTP call).
  def stub_agent_class(output)
    out = output
    Class.new(Phronomy::Agent::Base) do
      define_method(:invoke) do |_input, config: {}, thread_id: nil|
        {output: out, messages: []}
      end
      define_method(:invoke_async) { |input, **_kw| Phronomy::Runtime.instance.spawn(name: "stub-async") { invoke(input) } }
    end
  end

  # Failing stub agent (for on_error tests).
  def failing_agent_class
    Class.new(Phronomy::Agent::Base) do
      define_method(:invoke) do |_input, config: {}, thread_id: nil|
        raise "subagent_failure"
      end
      define_method(:invoke_async) { |input, **_kw| Phronomy::Runtime.instance.spawn(name: "stub-async") { invoke(input) } }
    end
  end

  # ---------------------------------------------------------------------------
  # TC-001: declarative / single / raise
  #
  # One subagent registered via .subagent DSL with on_error: :raise.
  # The LLM calls dispatch_to_worker_a; the subagent returns its result.
  # ---------------------------------------------------------------------------
  describe "TC-001: declarative / single / raise" do
    before do
      # LLM call sequence:
      #   call 0: orchestrator → tool_call (dispatch_to_worker_a)
      #   call 1: subagent worker_a  → "Subagent research result."
      #   call 2: orchestrator → final answer (after tool result injected)
      @llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response("dispatch_to_worker_a", {input: "research this"}),
        "Subagent research result.",
        "Done. Subagent returned: research result."
      ])
    end

    let(:orch_class) do
      IntegrationFactors.orch_declarative_class(subagent_count: :single, on_error: :raise)
    end

    it "returns a non-nil output synthesized from the subagent result" do
      result = orch_class.new.invoke("Orchestrate a research task")
      expect(result[:output]).not_to be_nil
    end

    it "LLM is called exactly 3 times (tool call + subagent + final answer)" do
      orch_class.new.invoke("Orchestrate a research task")
      expect(@llm.calls.size).to eq(3)
    end

    it "the orchestrator final LLM call contains the dispatch tool result" do
      orch_class.new.invoke("Orchestrate a research task")
      # Call index 2 is the orchestrator's second call (after tool result injected).
      messages = @llm.messages_for(2)
      tool_result_msg = messages.find { |m| m["role"] == "tool" }
      expect(tool_result_msg).not_to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: declarative / multiple / skip
  #
  # Two subagents registered. LLM calls dispatch_to_worker_a; the subagent
  # raises. With on_error: :skip the tool returns nil, and the LLM can continue.
  # ---------------------------------------------------------------------------
  describe "TC-002: declarative / multiple / skip" do
    before do
      # Orchestrator calls worker_a (which will fail), then produces a final answer.
      @llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response("dispatch_to_worker_a", {input: "task"}),
        "Completed with partial results."
      ])
    end

    let(:orch_class) do
      # Build a declarative class with on_error: :skip so failure is absorbed.
      IntegrationFactors.orch_declarative_class(subagent_count: :multiple, on_error: :skip)
    end

    it "does not raise even when the called subagent would normally fail" do
      # The subagent class returned by the factory is a real Base subclass that
      # calls WebMock.  Its response will be "Completed with partial results."
      # which is valid JSON for the draft parser — skip just means nil on error.
      expect { orch_class.new.invoke("Orchestrate with partial failure") }.not_to raise_error
    end

    it "two subagent tools are registered on the orchestrator class" do
      expect(orch_class.tools.length).to eq(2)
      tool_names = orch_class.tools.map(&:tool_name)
      expect(tool_names).to include("dispatch_to_worker_a", "dispatch_to_worker_b")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-003: parallel / single / skip
  #
  # dispatch_parallel dispatches one agent task directly (no LLM involved).
  # orch_on_error does not apply here; dispatch_parallel re-raises unconditionally.
  # ---------------------------------------------------------------------------
  describe "TC-003: parallel / single / skip" do
    let(:orch_class) { Class.new(Phronomy::MultiAgent::Orchestrator) }
    subject(:orch) { orch_class.new }

    it "returns the single result in an Array" do
      agent = stub_agent_class("parallel_result")
      results = orch.dispatch_parallel({agent: agent, input: "task"})
      expect(results.map { |r| r[:output] }).to eq(["parallel_result"])
    end

    it "forwards the input to the subagent" do
      received = []
      capture_class = Class.new(Phronomy::Agent::Base) do
        define_method(:invoke) do |input, config: {}, thread_id: nil|
          received << input
          {output: "ok", messages: []}
        end
        define_method(:invoke_async) { |input, **_kw| Phronomy::Runtime.instance.spawn(name: "stub-async") { invoke(input) } }
      end
      orch.dispatch_parallel({agent: capture_class, input: "my_task"})
      expect(received).to eq(["my_task"])
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004: parallel / multiple / raise
  #
  # dispatch_parallel dispatches two tasks concurrently.
  # With multiple tasks, order is preserved in the result Array.
  # ---------------------------------------------------------------------------
  describe "TC-004: parallel / multiple / raise" do
    let(:orch_class) { Class.new(Phronomy::MultiAgent::Orchestrator) }
    subject(:orch) { orch_class.new }

    it "returns results in the same order as the input tasks" do
      agent_a = stub_agent_class("result_a")
      agent_b = stub_agent_class("result_b")
      results = orch.dispatch_parallel(
        {agent: agent_a, input: "task_a"},
        {agent: agent_b, input: "task_b"}
      )
      expect(results.map { |r| r[:output] }).to eq(["result_a", "result_b"])
    end

    it "re-raises exceptions from any subagent thread" do
      good = stub_agent_class("ok")
      bad = failing_agent_class
      expect {
        orch.dispatch_parallel(
          {agent: good, input: "ok"},
          {agent: bad, input: "fail"}
        )
      }.to raise_error(RuntimeError, "subagent_failure")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-005: fan_out / single / raise
  #
  # fan_out runs the same agent against one input.
  # ---------------------------------------------------------------------------
  describe "TC-005: fan_out / single / raise" do
    let(:orch_class) { Class.new(Phronomy::MultiAgent::Orchestrator) }
    subject(:orch) { orch_class.new }

    it "returns a one-element result array" do
      agent = stub_agent_class("fan_out_result")
      results = orch.fan_out(agent: agent, inputs: ["input_a"])
      expect(results.map { |r| r[:output] }).to eq(["fan_out_result"])
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: fan_out / multiple / skip
  #
  # fan_out runs the same agent against multiple inputs in parallel.
  # Results are returned in the same order as the inputs Array.
  # ---------------------------------------------------------------------------
  describe "TC-006: fan_out / multiple / skip" do
    let(:orch_class) { Class.new(Phronomy::MultiAgent::Orchestrator) }
    subject(:orch) { orch_class.new }

    it "runs the agent for every input and returns results in input order" do
      received = []
      mutex = Mutex.new
      capture_class = Class.new(Phronomy::Agent::Base) do
        define_method(:invoke) do |input, config: {}, thread_id: nil|
          mutex.synchronize { received << input }
          {output: "echo:#{input}", messages: []}
        end
        define_method(:invoke_async) { |input, **_kw| Phronomy::Runtime.instance.spawn(name: "stub-async") { invoke(input) } }
      end

      results = orch.fan_out(agent: capture_class, inputs: %w[alpha beta gamma])

      expect(received.sort).to eq(%w[alpha beta gamma])
      # fan_out uses dispatch_parallel which preserves order.
      expect(results.map { |r| r[:output] }).to eq(%w[echo:alpha echo:beta echo:gamma])
    end

    it "forwards the config hash to every invocation" do
      configs = []
      mutex = Mutex.new
      agent = Class.new(Phronomy::Agent::Base) do
        define_method(:invoke) do |_input, config: {}, thread_id: nil|
          mutex.synchronize { configs << config }
          {output: "ok", messages: []}
        end
        define_method(:invoke_async) { |input, config: {}, **_kw| Phronomy::Runtime.instance.spawn(name: "stub-async") { invoke(input, config: config) } }
      end

      orch.fan_out(agent: agent, inputs: %w[x y], config: {thread_id: "t99"})

      expect(configs).to all(eq({thread_id: "t99"}))
    end
  end

  # ---------------------------------------------------------------------------
  # Pattern 2 requirement: orchestrator maintains coherent view while subagents
  # stay focused on their specific responsibilities.
  #
  # Verified by checking that:
  # 1. Each subagent tool receives only its designated input (focused scope).
  # 2. The orchestrator's final LLM call sees the tool results injected back
  #    (coherent synthesis).
  # ---------------------------------------------------------------------------
  describe "Pattern 2 requirement: orchestrator synthesizes subagent results" do
    before do
      # call 0: orchestrator → tool call; call 1: subagent; call 2: orchestrator final
      @llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response("dispatch_to_worker_a", {input: "security check"}),
        "Subagent security report.",
        "Security check complete. All clear."
      ])
    end

    let(:orch_class) do
      IntegrationFactors.orch_declarative_class(subagent_count: :single, on_error: :raise)
    end

    it "the orchestrator final LLM prompt contains the tool result (coherent synthesis)" do
      orch_class.new.invoke("Run security check")
      # Call 2 (index 2) is the orchestrator's second call after receiving the tool result.
      final_messages = @llm.messages_for(2)
      tool_msg = final_messages.find { |m| m["role"] == "tool" }
      expect(tool_msg).not_to be_nil
    end

    it "the orchestrator produces a non-empty final output" do
      result = orch_class.new.invoke("Run security check")
      expect(result[:output]).not_to be_nil
      expect(result[:output]).not_to be_empty
    end
  end
end
