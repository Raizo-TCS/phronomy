# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/llm_stub"

# Group 13: Subgraph nesting / Agent-as-Tool (rewritten with Phronomy::Workflow DSL)
# TC-001..TC-003: pure workflow tests (no LLM calls)
# TC-008..TC-010: LLM-required tests (AgentTool with ReactAgent)

RSpec.describe "Group 13: Subgraph / Agent-as-Tool", :integration do
  class G13BaseState
    include Phronomy::WorkflowContext

    field :value, type: :replace
    field :step, type: :replace, default: 0
    field :log, type: :append, default: -> { [] }
    field :meta, type: :merge, default: -> { {} }
  end

  class G13SubState
    include Phronomy::WorkflowContext

    field :value, type: :replace
    field :step, type: :replace, default: 0
  end

  def linear_subworkflow
    Phronomy::Workflow.define(G13SubState) do
      initial :s1
      state :s1, action: ->(s) { s.merge(value: "#{s.value}_s1", step: s.step + 1) }
      state :s2, action: ->(s) { s.merge(value: "#{s.value}_s2", step: s.step + 1) }
      after :s1, to: :s2
      after :s2, to: :__finish__
    end
  end

  def branching_subworkflow
    Phronomy::Workflow.define(G13SubState) do
      initial :router
      state :router, action: ->(s) { s }
      state :high, action: ->(s) { s.merge(value: "high_#{s.value}", step: s.step + 1) }
      state :low, action: ->(s) { s.merge(value: "low_#{s.value}", step: s.step + 1) }
      after :high, to: :__finish__
      after :low, to: :__finish__
      event :route, from: :router, guard: ->(s) { s.value.to_s.start_with?("h") }, to: :high
      event :route, from: :router, to: :low
    end
  end

  # ---------------------------------------------------------------------------
  # TC-001: flat workflow (no subgraph, no parallel) — baseline
  # ---------------------------------------------------------------------------
  it "TC-001: flat linear workflow executes all states in order" do
    app = Phronomy::Workflow.define(G13BaseState) do
      initial :a
      state :a, action: ->(s) { s.merge(value: "a", step: s.step + 1) }
      state :b, action: ->(s) { s.merge(value: "#{s.value}_b", step: s.step + 1) }
      after :a, to: :b
      after :b, to: :__finish__
    end
    final = app.invoke({})
    expect(final.value).to eq("a_b")
    expect(final.step).to eq(2)
  end

  # ---------------------------------------------------------------------------
  # TC-002: linear sub-workflow embedded via state action
  # ---------------------------------------------------------------------------
  it "TC-002: linear sub-workflow result is merged into parent state" do
    sub = linear_subworkflow
    app = Phronomy::Workflow.define(G13BaseState) do
      initial :before
      state :before, action: ->(s) { s.merge(value: "init", step: 0) }
      state :nested, action: ->(s) {
        result = sub.invoke({value: s.value, step: s.step})
        s.merge(value: result.value, step: result.step)
      }
      state :after, action: ->(s) { s.merge(value: "#{s.value}_after") }
      after :before, to: :nested
      after :nested, to: :after
      after :after, to: :__finish__
    end
    final = app.invoke({})
    expect(final.value).to eq("init_s1_s2_after")
    expect(final.step).to eq(2)
  end

  # ---------------------------------------------------------------------------
  # TC-003: branching sub-workflow (conditional routing inside sub-workflow)
  # ---------------------------------------------------------------------------
  it "TC-003: branching sub-workflow routes correctly based on input value" do
    sub = branching_subworkflow
    app = Phronomy::Workflow.define(G13BaseState) do
      initial :nested
      state :nested, action: ->(s) {
        result = sub.invoke({value: "high_input", step: 0})
        s.merge(value: result.value)
      }
      after :nested, to: :__finish__
    end
    final = app.invoke({})
    expect(final.value).to start_with("high_")
  end

  # ---------------------------------------------------------------------------
  # TC-008: AgentTool.from_agent generates a tool with correct name/description
  # ---------------------------------------------------------------------------
  it "TC-008: AgentTool.from_agent generates a tool with the expected name and description" do
    stub_agent = Class.new(Phronomy::Agent::Base) do
      def self.name
        "SummarizerAgent"
      end
    end
    tool_klass = Phronomy::Tool::AgentTool.from_agent(
      stub_agent,
      description: "Summarizes long documents"
    )
    expect(tool_klass.new.name).to eq("summarizer")
    expect(tool_klass.description).to eq("Summarizes long documents")
    expect(tool_klass.ancestors).to include(Phronomy::Tool::AgentTool)
  end

  # ---------------------------------------------------------------------------
  # TC-009: AgentTool with explicit tool_name overrides auto-derived name
  # ---------------------------------------------------------------------------
  it "TC-009: AgentTool respects an explicit tool_name override" do
    stub_agent = Class.new(Phronomy::Agent::Base) do
      def self.name
        "TranslatorAgent"
      end
    end
    tool_klass = Phronomy::Tool::AgentTool.from_agent(
      stub_agent,
      tool_name: "my_translator",
      description: "Translates text"
    )
    expect(tool_klass.new.name).to eq("my_translator")
  end

  # ---------------------------------------------------------------------------
  # TC-010: ReactAgent uses AgentTool to delegate to a sub-agent (LLM required)
  # ---------------------------------------------------------------------------
  it "TC-010: ReactAgent delegates a question to a wrapped sub-agent via AgentTool" do
    sub_agent_class = Class.new(Phronomy::Agent::Base) do
      model LM_STUDIO_MODEL
      provider :openai
      instructions "You are a math agent. Answer the arithmetic question concisely with only the numeric result."
    end
    sub_agent_class.define_singleton_method(:name) { "MathAgent" }

    math_tool = Phronomy::Tool::AgentTool.from_agent(
      sub_agent_class,
      tool_name: "math_solver",
      description: "Solves arithmetic questions. Pass the full question as input."
    )

    parent_class = Class.new(Phronomy::Agent::ReactAgent) do
      model LM_STUDIO_MODEL
      provider :openai
      instructions "You are an orchestrator. Use the math_solver tool to answer math questions. Do not answer yourself."
      tools math_tool
    end

    tool_resp = LLMStub.tool_call_response("math_solver", {input: "What is 12 multiplied by 9? Use the math_solver tool."})
    LLMStub.activate(responses: [tool_resp, "108", "The answer is 108."])

    result = parent_class.new.invoke("What is 12 multiplied by 9? Use the math_solver tool.")
    expect(result[:output]).to be_a(String)
    expect(result[:output]).not_to be_empty
    expect(result[:output]).to include("108")
  ensure
    LLMStub.deactivate
  end
end
