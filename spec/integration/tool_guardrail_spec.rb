# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Group 2: Tool / Guardrail
# Pairwise factors: agent_class × agent_tools × tool_on_error × tool_requires_approval
#                   × tool_param_enum × tool_name_override × agent_guardrails
# Feasible cases: 31
# Infeasible (3): R-enum — tool_param_enum != none with agent_tools = none
#
# Strategy:
#   - blocking_input cases: LLM never called → GuardrailError without LLM
#   - blocking_output cases: 1 LLM call → GuardrailError after
#   - invalid_value (tool_param_enum): direct tool.call() confirms ToolError (no LLM needed)
#   - requires_approval?: verified via tool instance (no LLM needed)
#   - All other cases: agent.invoke smoke test — expect String output

RSpec.describe "Group 2: Tool / Guardrail", :integration do
  after { LLMStub.deactivate }

  # Helper: build an agent with optional guardrails attached
  def build_agent(agent_label, tools:, guardrails: [])
    klass = IntegrationFactors.agent_class(agent_label, tools: tools)
    agent = klass.new
    IntegrationFactors.apply_guardrails(agent, guardrails)
    agent
  end

  # Shared fixture references
  let(:enum_tool_class) { IntegrationFactors::EnumCitySelectorTool }
  let(:calc_tool_class) { IntegrationFactors::CalculatorTool }
  let(:weather_tool_class) { IntegrationFactors::WeatherTool }
  let(:return_empty_tool) { IntegrationFactors::ReturnEmptyOnErrorTool }

  # -------------------------------------------------------------------------
  # TC-001: base, no tools, raise, false, none, nil, none — minimal smoke test
  # -------------------------------------------------------------------------
  describe "TC-001: base; no tools; no guardrails — smoke test" do
    let(:agent) { build_agent("base", tools: []) }

    before { @llm = LLMStub.activate(responses: ["Hello!"]) }

    it "returns a non-empty String output" do
      result = agent.invoke("Reply with exactly: Hello!")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # -------------------------------------------------------------------------
  # TC-002: base, splat_single, return_empty, requires_approval=true,
  #         valid_enum, explicit_name, input_only
  # -------------------------------------------------------------------------
  describe "TC-002: base; single tool (return_empty, requires_approval, explicit_name, valid_enum); input guardrail" do
    let(:tool_class) do
      Class.new(Phronomy::Tool::Base) do
        tool_name "city_info"
        description "Returns a short fact about a supported city"
        param :city, type: :string, desc: "One of: Tokyo, London, Paris",
          enum: %w[Tokyo London Paris]
        on_error :return_empty
        requires_approval true

        def execute(city:)
          "#{city} is a great destination."
        end
      end
    end
    let(:agent) do
      build_agent("base", tools: [tool_class],
        guardrails: IntegrationFactors.guardrails("input_only"))
    end

    before { @llm = LLMStub.activate(responses: ["Tokyo is a great destination."]) }

    it "requires_approval? returns true on the tool" do
      expect(tool_class.new.requires_approval?).to be true
    end

    it "agent invokes without raising (approval gate is caller responsibility)" do
      result = agent.invoke("Tell me about Tokyo.")
      expect(result[:output]).to be_a(String)
    end
  end

  # -------------------------------------------------------------------------
  # TC-003: base, splat_multi, raise, requires_approval=true,
  #         invalid_enum, nil, output_only
  # -------------------------------------------------------------------------
  describe "TC-003: base; multi tools; invalid enum triggers ToolError (direct); output guardrail" do
    let(:agent) do
      build_agent("base", tools: IntegrationFactors.tools("splat_multi"),
        guardrails: IntegrationFactors.guardrails("output_only"))
    end

    before { @llm = LLMStub.activate(responses: ["The weather in Paris is sunny."]) }

    it "EnumCitySelectorTool raises ToolError when called with an invalid city (direct call)" do
      expect {
        enum_tool_class.new.call({"city" => "InvalidCity"})
      }.to raise_error(Phronomy::ToolError)
    end

    it "agent with output_only (passing) guardrail returns output for a normal query" do
      result = agent.invoke("What is the weather in Paris?")
      expect(result[:output]).to be_a(String)
    end
  end

  # -------------------------------------------------------------------------
  # TC-004: base, hash_alias, raise, false, valid_enum, explicit, both guardrails
  # -------------------------------------------------------------------------
  describe "TC-004: base; hash-aliased tool; valid enum; both (passing) guardrails" do
    let(:agent) do
      build_agent("base", tools: IntegrationFactors.tools("hash_alias"),
        guardrails: IntegrationFactors.guardrails("both"))
    end

    before { @llm = LLMStub.activate(responses: ["7"]) }

    it "agent with both passing guardrails and aliased calculator returns output" do
      result = agent.invoke("Add 3 and 4. Return only the number.")
      expect(result[:output]).to be_a(String)
    end
  end

  # -------------------------------------------------------------------------
  # TC-005: base, hash_no_alias, raise, false, invalid_enum, explicit,
  #         blocking_input — LLM never called
  # -------------------------------------------------------------------------
  describe "TC-005: base; hash_no_alias tool; blocking_input guardrail fires before LLM" do
    let(:agent) do
      build_agent("base", tools: IntegrationFactors.tools("hash_no_alias"),
        guardrails: IntegrationFactors.guardrails("blocking_input"))
    end

    it "raises GuardrailError before the LLM is called" do
      expect { agent.invoke("Any input") }.to raise_error(Phronomy::GuardrailError)
    end
  end

  # -------------------------------------------------------------------------
  # TC-007: react, no tools, raise, requires_approval=true, none,
  #         explicit (no effect), blocking_output
  # -------------------------------------------------------------------------
  describe "TC-007: react; no tools; blocking_output guardrail fires after LLM" do
    let(:agent) do
      build_agent("react", tools: [],
        guardrails: IntegrationFactors.guardrails("blocking_output"))
    end

    before { @llm = LLMStub.activate(responses: ["I am an AI assistant."]) }

    it "raises GuardrailError after the LLM call (output guardrail)" do
      expect { agent.invoke("Describe yourself briefly.") }.to raise_error(Phronomy::GuardrailError)
    end
  end

  # -------------------------------------------------------------------------
  # TC-008: react, splat_single, raise, false, invalid_enum, nil, input_only
  # -------------------------------------------------------------------------
  describe "TC-008: react; single enum tool; invalid_enum raises ToolError (direct); input guardrail" do
    let(:agent) do
      build_agent("react", tools: [enum_tool_class],
        guardrails: IntegrationFactors.guardrails("input_only"))
    end

    before { @llm = LLMStub.activate(responses: ["London is the capital of England."]) }

    it "EnumCitySelectorTool raises ToolError for an invalid city (direct call)" do
      expect {
        enum_tool_class.new.call({"city" => "Berlin"})
      }.to raise_error(Phronomy::ToolError)
    end

    it "agent with passing input guardrail invokes without raising" do
      result = agent.invoke("Tell me about London.")
      expect(result[:output]).to be_a(String)
    end
  end

  # -------------------------------------------------------------------------
  # TC-009: react, splat_multi, return_empty, false, none, explicit, output_only
  # -------------------------------------------------------------------------
  describe "TC-009: react; multi tools (one return_empty); passing output guardrail" do
    let(:agent) do
      klass = IntegrationFactors.agent_class(
        "react", tools: [return_empty_tool, weather_tool_class]
      )
      a = klass.new
      IntegrationFactors.apply_guardrails(a, IntegrationFactors.guardrails("output_only"))
      a
    end

    before { @llm = LLMStub.activate(responses: ["The weather in Tokyo is sunny and warm."]) }

    it "agent continues even when error tool returns empty; output guardrail passes" do
      result = agent.invoke("What is the weather in Tokyo?")
      expect(result[:output]).to be_a(String)
    end
  end

  # -------------------------------------------------------------------------
  # TC-010: react, hash_alias, return_empty, requires_approval=true, none,
  #         nil, blocking_input — LLM never called
  # -------------------------------------------------------------------------
  describe "TC-010: react; hash-aliased tool (requires_approval=true); blocking_input" do
    let(:tool_class) do
      parent_desc = IntegrationFactors::CalculatorTool.description
      Class.new(IntegrationFactors::CalculatorTool) do
        description parent_desc
        requires_approval true
        on_error :return_empty
      end
    end
    let(:agent) do
      klass = IntegrationFactors.agent_class("react", tools: {tool_class => "calc_alias"})
      a = klass.new
      IntegrationFactors.apply_guardrails(a, IntegrationFactors.guardrails("blocking_input"))
      a
    end

    it "requires_approval? returns true" do
      expect(tool_class.new.requires_approval?).to be true
    end

    it "raises GuardrailError before LLM (blocking_input)" do
      expect { agent.invoke("Add 1 and 2.") }.to raise_error(Phronomy::GuardrailError)
    end
  end

  # -------------------------------------------------------------------------
  # TC-011: react, hash_no_alias, return_empty, requires_approval=true,
  #         valid_enum, nil, none
  # -------------------------------------------------------------------------
  describe "TC-011: react; hash_no_alias enum tool; requires_approval=true; no guardrails" do
    let(:tool_class) do
      parent_desc = IntegrationFactors::EnumCitySelectorTool.description
      Class.new(IntegrationFactors::EnumCitySelectorTool) do
        description parent_desc
        requires_approval true
        on_error :return_empty
      end
    end
    let(:agent) { IntegrationFactors.agent_class("react", tools: {tool_class => nil}).new }

    before { @llm = LLMStub.activate(responses: ["Paris is the capital of France."]) }

    it "requires_approval? returns true" do
      expect(tool_class.new.requires_approval?).to be true
    end

    it "agent invokes without raising (approval gate is caller responsibility)" do
      result = agent.invoke("Tell me about Paris.")
      expect(result[:output]).to be_a(String)
    end
  end

  # -------------------------------------------------------------------------
  # TC-012: react, no tools, return_empty, requires_approval=true, none, nil, both
  # -------------------------------------------------------------------------
  describe "TC-012: react; no tools; both (passing) guardrails" do
    let(:agent) do
      build_agent("react", tools: [], guardrails: IntegrationFactors.guardrails("both"))
    end

    before { @llm = LLMStub.activate(responses: ["OK"]) }

    it "both passing guardrails allow invocation to succeed" do
      result = agent.invoke("Say 'OK'.")
      expect(result[:output]).to be_a(String)
    end
  end

  # -------------------------------------------------------------------------
  # TC-014: base, no tools, raise, false, none, nil, input_only
  # -------------------------------------------------------------------------
  describe "TC-014: base; no tools; input_only (passing) guardrail" do
    let(:agent) do
      build_agent("base", tools: [], guardrails: IntegrationFactors.guardrails("input_only"))
    end

    before { @llm = LLMStub.activate(responses: ["Yes"]) }

    it "input guardrail passes and agent returns output" do
      result = agent.invoke("Say 'Yes'.")
      expect(result[:output]).to be_a(String)
    end
  end

  # -------------------------------------------------------------------------
  # TC-016: base, splat_single, raise, false, none, nil, none — baseline tool
  # -------------------------------------------------------------------------
  describe "TC-016: base; single tool (splat); no guardrails — baseline" do
    let(:agent) { build_agent("base", tools: IntegrationFactors.tools("splat_single")) }

    before { @llm = LLMStub.activate(responses: ["30"]) }

    it "agent with calculator registered returns a result" do
      result = agent.invoke("Add 10 and 20 using the calculator. Return only the number.")
      expect(result[:output]).to be_a(String)
    end
  end

  # -------------------------------------------------------------------------
  # TC-017: base, splat_single, raise, false, none, nil, output_only
  # -------------------------------------------------------------------------
  describe "TC-017: base; single tool; output_only (passing) guardrail" do
    let(:agent) do
      build_agent("base", tools: IntegrationFactors.tools("splat_single"),
        guardrails: IntegrationFactors.guardrails("output_only"))
    end

    before { @llm = LLMStub.activate(responses: ["12"]) }

    it "output guardrail passes and agent returns output" do
      result = agent.invoke("Add 5 and 7. Return only the number.")
      expect(result[:output]).to be_a(String)
    end
  end

  # -------------------------------------------------------------------------
  # TC-018: base, splat_single, raise, false, invalid_enum, nil, both guardrails
  # -------------------------------------------------------------------------
  describe "TC-018: base; single enum tool; invalid_enum raises ToolError (direct); both passing guardrails" do
    let(:agent) do
      build_agent("base", tools: [enum_tool_class],
        guardrails: IntegrationFactors.guardrails("both"))
    end

    before { @llm = LLMStub.activate(responses: ["London is the capital of England."]) }

    it "EnumCitySelectorTool.call with invalid city raises ToolError" do
      expect {
        enum_tool_class.new.call({"city" => "Sydney"})
      }.to raise_error(Phronomy::ToolError)
    end

    it "agent with both passing guardrails invokes normally" do
      result = agent.invoke("Tell me about London.")
      expect(result[:output]).to be_a(String)
    end
  end

  # -------------------------------------------------------------------------
  # TC-019: base, splat_single, raise, false, none, nil, blocking_input — NO LLM
  # -------------------------------------------------------------------------
  describe "TC-019: base; single tool; blocking_input guardrail fires before LLM" do
    let(:agent) do
      build_agent("base", tools: IntegrationFactors.tools("splat_single"),
        guardrails: IntegrationFactors.guardrails("blocking_input"))
    end

    it "raises GuardrailError before LLM" do
      expect { agent.invoke("Add 1 and 2.") }.to raise_error(Phronomy::GuardrailError)
    end
  end

  # -------------------------------------------------------------------------
  # TC-020: base, splat_single, raise, false, valid_enum, nil, blocking_output
  # -------------------------------------------------------------------------
  describe "TC-020: base; single enum tool; valid_enum; blocking_output guardrail" do
    let(:agent) do
      build_agent("base", tools: [enum_tool_class],
        guardrails: IntegrationFactors.guardrails("blocking_output"))
    end

    before { @llm = LLMStub.activate(responses: ["Tokyo is the capital of Japan."]) }

    it "raises GuardrailError after LLM (blocking_output)" do
      expect { agent.invoke("Tell me about Tokyo.") }.to raise_error(Phronomy::GuardrailError)
    end
  end

  # -------------------------------------------------------------------------
  # TC-021: base, splat_multi, raise, false, valid_enum, nil, none
  # -------------------------------------------------------------------------
  describe "TC-021: base; multi tools; valid enum tool included; no guardrails" do
    let(:agent) { build_agent("base", tools: [calc_tool_class, enum_tool_class]) }

    before { @llm = LLMStub.activate(responses: ["5"]) }

    it "agent returns output (calculator or city tool)" do
      result = agent.invoke("Add 2 and 3. Return only the number.")
      expect(result[:output]).to be_a(String)
    end
  end

  # -------------------------------------------------------------------------
  # TC-022: base, splat_multi, raise, false, none, nil, input_only
  # -------------------------------------------------------------------------
  describe "TC-022: base; multi tools; input_only (passing) guardrail" do
    let(:agent) do
      build_agent("base", tools: IntegrationFactors.tools("splat_multi"),
        guardrails: IntegrationFactors.guardrails("input_only"))
    end

    before { @llm = LLMStub.activate(responses: ["13"]) }

    it "input guardrail passes and agent returns output" do
      result = agent.invoke("What is 6 + 7? Return only the number.")
      expect(result[:output]).to be_a(String)
    end
  end

  # -------------------------------------------------------------------------
  # TC-023: base, splat_multi, raise, false, none, nil, both
  # -------------------------------------------------------------------------
  describe "TC-023: base; multi tools; both (passing) guardrails" do
    let(:agent) do
      build_agent("base", tools: IntegrationFactors.tools("splat_multi"),
        guardrails: IntegrationFactors.guardrails("both"))
    end

    before { @llm = LLMStub.activate(responses: ["Sunny in London."]) }

    it "both passing guardrails allow invocation to succeed" do
      result = agent.invoke("What is the weather in London?")
      expect(result[:output]).to be_a(String)
    end
  end

  # -------------------------------------------------------------------------
  # TC-024: base, splat_multi, raise, false, none, nil, blocking_input — NO LLM
  # -------------------------------------------------------------------------
  describe "TC-024: base; multi tools; blocking_input guardrail fires before LLM" do
    let(:agent) do
      build_agent("base", tools: IntegrationFactors.tools("splat_multi"),
        guardrails: IntegrationFactors.guardrails("blocking_input"))
    end

    it "raises GuardrailError before LLM" do
      expect { agent.invoke("Compute 1 + 1.") }.to raise_error(Phronomy::GuardrailError)
    end
  end

  # -------------------------------------------------------------------------
  # TC-025: base, splat_multi, raise, false, none, nil, blocking_output
  # -------------------------------------------------------------------------
  describe "TC-025: base; multi tools; blocking_output guardrail fires after LLM" do
    let(:agent) do
      build_agent("base", tools: IntegrationFactors.tools("splat_multi"),
        guardrails: IntegrationFactors.guardrails("blocking_output"))
    end

    before { @llm = LLMStub.activate(responses: ["The answer is 10."]) }

    it "raises GuardrailError after LLM (blocking_output)" do
      expect { agent.invoke("What is 5 + 5?") }.to raise_error(Phronomy::GuardrailError)
    end
  end

  # -------------------------------------------------------------------------
  # TC-026: base, hash_alias, raise, false, invalid_enum, nil, none
  # -------------------------------------------------------------------------
  describe "TC-026: base; hash-aliased enum tool; invalid_enum raises ToolError (direct); no guardrails" do
    let(:agent) { build_agent("base", tools: {enum_tool_class => "city_lookup"}) }

    before { @llm = LLMStub.activate(responses: ["Paris is a wonderful city."]) }

    it "EnumCitySelectorTool.call with invalid city raises ToolError" do
      expect {
        enum_tool_class.new.call({"city" => "Moscow"})
      }.to raise_error(Phronomy::ToolError)
    end

    it "agent with hash-aliased enum tool invokes normally" do
      result = agent.invoke("Tell me about Paris.")
      expect(result[:output]).to be_a(String)
    end
  end

  # -------------------------------------------------------------------------
  # TC-027: base, hash_alias, raise, false, none, nil, input_only
  # -------------------------------------------------------------------------
  describe "TC-027: base; hash-aliased calc tool; input_only (passing) guardrail" do
    let(:agent) do
      build_agent("base", tools: IntegrationFactors.tools("hash_alias"),
        guardrails: IntegrationFactors.guardrails("input_only"))
    end

    before { @llm = LLMStub.activate(responses: ["12"]) }

    it "input guardrail passes and aliased-tool agent returns output" do
      result = agent.invoke("Add 3 and 9. Return only the number.")
      expect(result[:output]).to be_a(String)
    end
  end

  # -------------------------------------------------------------------------
  # TC-028: base, hash_alias, raise, false, none, nil, output_only
  # -------------------------------------------------------------------------
  describe "TC-028: base; hash-aliased calc tool; output_only (passing) guardrail" do
    let(:agent) do
      build_agent("base", tools: IntegrationFactors.tools("hash_alias"),
        guardrails: IntegrationFactors.guardrails("output_only"))
    end

    before { @llm = LLMStub.activate(responses: ["12"]) }

    it "output guardrail passes and aliased-tool agent returns output" do
      result = agent.invoke("Add 4 and 8. Return only the number.")
      expect(result[:output]).to be_a(String)
    end
  end

  # -------------------------------------------------------------------------
  # TC-029: base, hash_alias, raise, false, none, nil, blocking_output
  # -------------------------------------------------------------------------
  describe "TC-029: base; hash-aliased calc tool; blocking_output guardrail" do
    let(:agent) do
      build_agent("base", tools: IntegrationFactors.tools("hash_alias"),
        guardrails: IntegrationFactors.guardrails("blocking_output"))
    end

    before { @llm = LLMStub.activate(responses: ["2"]) }

    it "raises GuardrailError after LLM (blocking_output)" do
      expect { agent.invoke("Add 1 and 1.") }.to raise_error(Phronomy::GuardrailError)
    end
  end

  # -------------------------------------------------------------------------
  # TC-030: base, hash_no_alias, raise, false, none, nil, input_only
  # -------------------------------------------------------------------------
  describe "TC-030: base; hash_no_alias tool; input_only (passing) guardrail" do
    let(:agent) do
      build_agent("base", tools: IntegrationFactors.tools("hash_no_alias"),
        guardrails: IntegrationFactors.guardrails("input_only"))
    end

    before { @llm = LLMStub.activate(responses: ["15"]) }

    it "input guardrail passes and nil-alias tool agent returns output" do
      result = agent.invoke("Add 6 and 9. Return only the number.")
      expect(result[:output]).to be_a(String)
    end
  end

  # -------------------------------------------------------------------------
  # TC-031: base, hash_no_alias, raise, false, none, nil, output_only
  # -------------------------------------------------------------------------
  describe "TC-031: base; hash_no_alias tool; output_only (passing) guardrail" do
    let(:agent) do
      build_agent("base", tools: IntegrationFactors.tools("hash_no_alias"),
        guardrails: IntegrationFactors.guardrails("output_only"))
    end

    before { @llm = LLMStub.activate(responses: ["10"]) }

    it "output guardrail passes and nil-alias tool agent returns output" do
      result = agent.invoke("Add 2 and 8. Return only the number.")
      expect(result[:output]).to be_a(String)
    end
  end

  # -------------------------------------------------------------------------
  # TC-032: base, hash_no_alias, raise, false, none, nil, both
  # -------------------------------------------------------------------------
  describe "TC-032: base; hash_no_alias tool; both (passing) guardrails" do
    let(:agent) do
      build_agent("base", tools: IntegrationFactors.tools("hash_no_alias"),
        guardrails: IntegrationFactors.guardrails("both"))
    end

    before { @llm = LLMStub.activate(responses: ["10"]) }

    it "both passing guardrails allow invocation to succeed" do
      result = agent.invoke("Add 7 and 3. Return only the number.")
      expect(result[:output]).to be_a(String)
    end
  end

  # -------------------------------------------------------------------------
  # TC-033: base, hash_no_alias, raise, false, none, nil, blocking_output
  # -------------------------------------------------------------------------
  describe "TC-033: base; hash_no_alias tool; blocking_output guardrail" do
    let(:agent) do
      build_agent("base", tools: IntegrationFactors.tools("hash_no_alias"),
        guardrails: IntegrationFactors.guardrails("blocking_output"))
    end

    before { @llm = LLMStub.activate(responses: ["4"]) }

    it "raises GuardrailError after LLM (blocking_output)" do
      expect { agent.invoke("Add 2 and 2.") }.to raise_error(Phronomy::GuardrailError)
    end
  end

  # -------------------------------------------------------------------------
  # TC-034: base, no tools, raise, false, none, explicit (no effect), none
  # -------------------------------------------------------------------------
  describe "TC-034: base; no tools; explicit tool_name_override has no effect; no guardrails" do
    let(:agent) { build_agent("base", tools: []) }

    before { @llm = LLMStub.activate(responses: ["Done."]) }

    it "agent behaves identically to no-tool baseline" do
      result = agent.invoke("Reply with exactly: Done.")
      expect(result[:output]).to be_a(String)
    end
  end
end
