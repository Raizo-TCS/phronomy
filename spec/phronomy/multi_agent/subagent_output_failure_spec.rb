# frozen_string_literal: true

require "spec_helper"
require_relative "support/durable_coordination"

RSpec.describe "Durable subagent output failures" do
  include_context "durable coordination runtime"

  def reject_output(agent_class)
    agent_class.output_filter Class.new(Phronomy::Filter::Base) {
      def call(value, **_context)
        raise Phronomy::Agent::OutputError.new(execution_id: "filter-output",
          schema_digest: "filter-contract", reason: "invalid_json", raw_output: value)
      end
    }
  end

  def orchestrator_with_policy(policy)
    child = worker
    Class.new(Phronomy::MultiAgent::Orchestrator) do
      agent_definition id: "output-failure-parent-#{policy}", version: 1
      model "gpt-4o-mini"
      provider :openai
      subagent :worker, child, on_error: policy
    end
  end

  def persisted_child(parent_run)
    state_ref = parent_run.metadata.fetch("execution_extension").fetch("state_ref")
    child = store.multi_agent.contents.fetch_json(state_ref).fetch("children").first
    store.agent.result(child.fetch("execution_id"))
  end

  it "raises the terminal child failure through the existing raise policy", :aggregate_failures do
    reject_output(worker)
    parent = orchestrator_with_policy(:raise).create(persistence: store.agent, coordination_store: store.multi_agent)
    llm = LLMStub.activate(responses: [LLMStub.tool_call_response("dispatch_to_worker", {input: "job"}), "invalid child output", "parent result"])

    expect { parent.invoke("plan") }.to raise_error(Phronomy::Agent::OutputError)
    run = store.agent.runs(parent.agent_id).first
    expect(run.status).to eq(:failed)
    expect(store.agent.result(run.execution_id).fetch(:error)).to include("class" => "Phronomy::Agent::OutputError")
    expect(persisted_child(run)).to include(status: :failed, error: hash_including("class" => "Phronomy::Agent::OutputError"))
    expect(llm.calls.size).to eq(2)
  end

  it "continues after the terminal child failure through the existing skip policy", :aggregate_failures do
    reject_output(worker)
    events = []
    parent = orchestrator_with_policy(:skip).create(persistence: store.agent, coordination_store: store.multi_agent,
      on_event: ->(event) { events << event })
    llm = LLMStub.activate(responses: [LLMStub.tool_call_response("dispatch_to_worker", {input: "job"}), "invalid child output", "parent result"])

    result = parent.invoke("plan")

    expect(result).to include(output: "parent result")
    run = store.agent.runs(parent.agent_id).first
    expect(run.status).to eq(:completed)
    expect(persisted_child(run)).to include(status: :failed, error: hash_including("class" => "Phronomy::Agent::OutputError"))
    expect(events.find { |event| event.type == :tool_result }.payload.fetch(:tool_result)).to be_nil
    expect(llm.calls.size).to eq(3)
  end

  it "preserves the HandoffRunner value! failure policy for a reserved target", :aggregate_failures do
    source = worker.create(agent_id: "output-source", persistence: store.agent)
    target_class = Class.new(worker) do
      agent_definition id: "output-failure-target", version: 1
    end
    reject_output(target_class)
    target = target_class.create(agent_id: "output-target", persistence: store.agent)
    edge = Phronomy::MultiAgent::Handoff.new(source_agent: source, target_agent: target)
    tool_name = Phronomy::MultiAgent::HandoffCapabilityFactory.build(edge).tool_name
    runner = Phronomy::MultiAgent::HandoffRunner.new(main_agent: source, persistence: store.multi_agent, handoffs: [edge])
    llm = LLMStub.activate(responses: [LLMStub.tool_call_response(tool_name, {responsibility: "delegated work"}), "invalid target output"])

    expect { runner.invoke("plan") }.to raise_error(Phronomy::Agent::OutputError)

    source_run = store.agent.runs(source.agent_id).first
    target_run = store.agent.runs(target.agent_id).first
    expect(source_run.status).to eq(:handed_off)
    expect(target_run.status).to eq(:failed)
    expect(runner.result(source_run.execution_id)).to include(agent_id: target.agent_id, status: :failed)
    expect(llm.calls.size).to eq(2)
  end
end
