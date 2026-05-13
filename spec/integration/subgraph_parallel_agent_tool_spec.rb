# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/llm_stub"

# Group 13: Subgraph nesting / Agent-as-Tool
# Pairwise factors: subgraph_type × agent_as_tool_wrapping
#
# TC-001..TC-003: pure graph tests (no LLM calls)
# TC-008..TC-010: LLM-required tests (AgentTool with ReactAgent)
#
# Feasible cases: 6
# Infeasible cases: 0

RSpec.describe "Group 13: Subgraph / Agent-as-Tool", :integration do
  # ---------------------------------------------------------------------------
  # State classes used across tests
  # ---------------------------------------------------------------------------

  class G13BaseState
    include Phronomy::Graph::Context

    field :value, type: :replace
    field :step, type: :replace, default: 0
    field :log, type: :append, default: -> { [] }
    field :meta, type: :merge, default: -> { {} }
  end

  class G13SubState
    include Phronomy::Graph::Context

    field :value, type: :replace
    field :step, type: :replace, default: 0
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  FINISH = Phronomy::Graph::StateGraph::FINISH

  def linear_subgraph
    sg = Phronomy::Graph::StateGraph.new(G13SubState)
    sg.add_node(:s1) { |s| {value: "#{s.value}_s1", step: s.step + 1} }
    sg.add_node(:s2) { |s| {value: "#{s.value}_s2", step: s.step + 1} }
    sg.set_entry_point(:s1)
    sg.add_edge(:s1, :s2)
    sg.add_edge(:s2, FINISH)
    sg.compile
  end

  def branching_subgraph
    sg = Phronomy::Graph::StateGraph.new(G13SubState)
    sg.add_node(:router) { |s| s }
    sg.add_node(:high) { |s| {value: "high_#{s.value}", step: s.step + 1} }
    sg.add_node(:low) { |s| {value: "low_#{s.value}", step: s.step + 1} }
    sg.set_entry_point(:router)
    sg.add_conditional_edges(:router,
      ->(s) { s.value.to_s.start_with?("h") ? :high : :low })
    sg.add_edge(:high, FINISH)
    sg.add_edge(:low, FINISH)
    sg.compile
  end

  # ---------------------------------------------------------------------------
  # TC-001: flat graph (no subgraph, no parallel) — baseline
  # ---------------------------------------------------------------------------

  it "TC-001: flat linear graph executes all nodes in order (no subgraph, no parallel)" do
    graph = Phronomy::Graph::StateGraph.new(G13BaseState)
    graph.add_node(:a) { |s| {value: "a", step: s.step + 1} }
    graph.add_node(:b) { |s| {value: "#{s.value}_b", step: s.step + 1} }
    graph.set_entry_point(:a)
    graph.add_edge(:a, :b)
    graph.add_edge(:b, FINISH)
    app = graph.compile

    final = app.invoke({})
    expect(final.value).to eq("a_b")
    expect(final.step).to eq(2)
  end

  # ---------------------------------------------------------------------------
  # TC-002: linear_2step subgraph embedded via add_subgraph
  # ---------------------------------------------------------------------------

  it "TC-002: linear subgraph result is merged into parent state" do
    sub = linear_subgraph

    parent = Phronomy::Graph::StateGraph.new(G13BaseState)
    parent.add_node(:before) { |s| {value: "init", step: 0} }
    parent.add_subgraph(:nested, sub)
    parent.add_node(:after) { |s| {value: "#{s.value}_after"} }
    parent.set_entry_point(:before)
    parent.add_edge(:before, :nested)
    parent.add_edge(:nested, :after)
    parent.add_edge(:after, FINISH)
    app = parent.compile

    final = app.invoke({})
    expect(final.value).to eq("init_s1_s2_after")
    expect(final.step).to eq(2)
  end

  # ---------------------------------------------------------------------------
  # TC-003: branching subgraph (conditional_edges inside subgraph)
  # ---------------------------------------------------------------------------

  it "TC-003: branching subgraph routes correctly based on input value" do
    sub = branching_subgraph

    parent = Phronomy::Graph::StateGraph.new(G13BaseState)
    parent.add_subgraph(:nested, sub,
      input_mapper: ->(s) { {value: "high_input"} },
      output_mapper: ->(sub_s) { {value: sub_s.value} })
    parent.set_entry_point(:nested)
    parent.add_edge(:nested, FINISH)
    app = parent.compile

    final = app.invoke({})
    expect(final.value).to start_with("high_")
  end

  # ---------------------------------------------------------------------------
  # TC-008: AgentTool.from_agent generates a tool with correct name/description
  # (no LLM call — pure unit-level check via integration spec)
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
  # (no LLM call)
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
    # Sub-agent: a simple calculator-style base agent.
    sub_agent_class = Class.new(Phronomy::Agent::Base) do
      model LM_STUDIO_MODEL
      provider :openai
      instructions "You are a math agent. Answer the arithmetic question concisely with only the numeric result."
    end
    sub_agent_class.define_singleton_method(:name) { "MathAgent" }

    math_tool = Phronomy::Tool::AgentTool.from_agent(
      sub_agent_class,
      tool_name: "math_solver",
      description: "Solves arithmetic questions. Pass the full question as 'input'."
    )

    parent_class = Class.new(Phronomy::Agent::ReactAgent) do
      model LM_STUDIO_MODEL
      provider :openai
      instructions "You are an orchestrator. Use the math_solver tool to answer math questions. Do not answer yourself."
      tools math_tool
    end

    # LLM call order:
    #   1. Parent ReactAgent LLM → tool_call("math_solver", {input: "..."})
    #   2. Sub-agent (MathAgent) LLM → "108"
    #   3. Parent ReactAgent LLM → final answer including "108"
    tool_resp = LLMStub.tool_call_response("math_solver", {input: "What is 12 multiplied by 9? Use the math_solver tool."})
    LLMStub.activate(responses: [tool_resp, "108", "The answer is 108."])

    result = parent_class.new.invoke("What is 12 multiplied by 9? Use the math_solver tool.")
    expect(result[:output]).to be_a(String)
    expect(result[:output]).not_to be_empty
    # The final answer should contain 108.
    expect(result[:output]).to include("108")
  ensure
    LLMStub.deactivate
  end
end
