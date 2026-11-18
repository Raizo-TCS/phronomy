# frozen_string_literal: true

require "spec_helper"
require_relative "support/durable_coordination"

RSpec.describe "Orchestrator Tool composition" do
  include_context "durable coordination runtime"

  let(:native_tool) { parent_class.tools.first }
  let(:ordinary_tool) do
    Class.new(Phronomy::Tool::Base) do
      tool_name "ordinary_tool"
      description "An unrelated application Tool"
      def execute = "ordinary"
    end
  end

  [nil, "consult_worker"].each do |alias_name|
    it "retains durable child dispatch and Knowledge with #{alias_name || "the native name"}" do
      derived = parent_class.with_tools({native_tool => alias_name, ordinary_tool => "inspect_source"},
        id: "composed-parent", version: 1)
      parent = derived.create(persistence: store.agent, coordination_store: store.multi_agent)
      parent.add_knowledge("saved knowledge", metadata: {"source" => "composition"})
      llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response(alias_name || "dispatch_to_worker", {input: "job"}),
        "child-result", "parent-result"
      ])

      result = parent.invoke("plan")

      expect(result[:output]).to eq("parent-result")
      extension = store.agent.execution_extension(agent_id: parent.agent_id,
        execution_id: result.fetch(:execution_id), binding_key: "phronomy.subagent")
      child = store.multi_agent.contents.fetch_json(extension.state_ref).fetch("children").fetch(0)
      expect(child).to include("name" => "worker", "imported" => true)
      knowledge = store.agent.knowledge_snapshot(agent_id: child.fetch("agent_id")).fetch(0)
      expect(knowledge.content).to eq("saved knowledge")
      expect(knowledge.metadata).to include("source" => "composition")
      expect(parent.unload_with_completed_child!(result.fetch(:execution_id), execution_id: child.fetch("execution_id"))).to be(true)
      expect(derived.get(parent.agent_id)).to be_nil
      expect(worker.get(child.fetch("agent_id"))).to be_nil
      expect(llm.calls.size).to eq(3)
      expect(parent_class.tool_aliases).not_to have_key(native_tool)
    end
  end

  it "keeps registration settings independent across retained and repeatedly derived Tools" do
    derived = parent_class.with_tools({native_tool => "consult_worker"}, id: "composed-parent", version: 1)
    repeated = derived.with_tools({native_tool => nil}, id: "recomposed-parent", version: 1)

    expect(derived.registered_subagents).to eq(parent_class.registered_subagents)
    expect(repeated.registered_subagents).to eq(parent_class.registered_subagents)
    repeated.registered_subagents.fetch(:worker)[:inherit_knowledge] = false
    repeated.registered_subagents.delete(:worker)
    expect(derived.registered_subagents.fetch(:worker)).to include(inherit_knowledge: true)
    expect(parent_class.registered_subagents.fetch(:worker)).to include(inherit_knowledge: true)
    expect(repeated.tool_aliases).not_to have_key(native_tool)
    expect(derived.tool_aliases).to include(native_tool => "consult_worker")
  end

  it "drops removed native registrations without changing the source or ordinary subclass rules" do
    removed = parent_class.with_tools({ordinary_tool => nil}, id: "without-child", version: 1)

    expect(removed.registered_subagents).to be_empty
    expect(removed._subagent_tool_classes).to be_empty
    expect(removed.tools).to eq([ordinary_tool])
    expect(parent_class.registered_subagents.keys).to eq([:worker])
    expect(parent_class._subagent_tool_classes).to eq([native_tool])
    expect(Class.new(parent_class).registered_subagents).to be_empty
  end

  it "keeps retained native dispatch subject to the coordination Store requirement" do
    derived = parent_class.with_tools({native_tool => nil}, id: "composed-parent", version: 1)
    parent = derived.create
    recorder = LLMStub.activate(responses: ["unexpected request"])

    expect { parent.invoke("plan") }.to raise_error(Phronomy::ConfigurationError, /coordination_store/)
    expect(recorder.calls).to be_empty
  end
end
