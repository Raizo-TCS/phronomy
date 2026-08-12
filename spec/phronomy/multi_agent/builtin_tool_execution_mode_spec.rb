# frozen_string_literal: true

require "spec_helper"

RSpec.describe "framework-owned short Tool execution modes" do
  it "marks Handoff's sentinel Tool cooperative" do
    target = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "handoff-mode-target", version: 1
      model "test"
    end.new

    tool_class = Phronomy::MultiAgent::Handoff.new(target_agent: target).to_tool_class

    expect(tool_class.execution_mode).to eq(:cooperative)
  end

  it "marks TeamCoordinator queue-management Tools cooperative" do
    coordinator = Phronomy::MultiAgent::TeamCoordinator.new
    queue = []

    enqueue_tool = coordinator.send(:build_enqueue_tool, queue)
    finalize_tool = coordinator.send(:build_finalize_tool, queue)

    expect(enqueue_tool.execution_mode).to eq(:cooperative)
    expect(finalize_tool.execution_mode).to eq(:cooperative)
  end

  it "marks SharedState in-memory knowledge Tools cooperative" do
    researcher = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "shared-state-mode-researcher", version: 1
      model "test"
    end
    shared_state = Phronomy::Agent::SharedState.new
    store = Phronomy::Agent::SharedState::KnowledgeStore.new

    instrumented = shared_state.send(
      :build_instrumented_researcher,
      researcher,
      store,
      1
    )
    internal_tools = instrumented.tools - researcher.tools

    expect(internal_tools.map(&:execution_mode)).to all(eq(:cooperative))
  end
end
