# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

RSpec.describe "Multi-Agent Handoff after ordinary Tool execution", :integration do
  after { LLMStub.deactivate }

  it "keeps the current user request in the current_request Handoff category" do
    lookup_tool = Class.new(Phronomy::Tool::Base) do
      tool_name "cg05_followup_lookup"
      description "Returns a deterministic lookup result for the CG-05 regression test"
      execution_mode :cooperative
      param :query, type: :string, desc: "Lookup query"

      define_method(:execute) do |query:|
        "lookup result for #{query}"
      end
    end

    source_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "cg05-followup-handoff-source", version: 1
      model IntegrationFactors::LM_MODEL_26
      provider :openai
      instructions "Use the lookup Tool first, then hand the case to the target Agent."
      tools(lookup_tool => nil)
    end

    target_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "cg05-followup-handoff-target", version: 1
      model IntegrationFactors::LM_MODEL_26
      provider :openai
      instructions "Finish the handed-off case."
    end

    source = source_class.new
    target = target_class.new
    policy = Phronomy::MultiAgent::HandoffPolicy.define do
      required :current_request
      forbidden :history
      selectable :knowledge, default: :exclude
      selectable :tool_exchanges, default: :include
    end
    handoff = Phronomy::MultiAgent::Handoff.new(
      source_agent: source,
      target_agent: target,
      policy: policy,
      description: "Transfer the case after the lookup"
    )
    transport_name = Phronomy::MultiAgent::HandoffCapabilityFactory.build(handoff).tool_name

    recorder = LLMStub.activate(responses: [
      LLMStub.tool_call_response(
        "cg05_followup_lookup",
        {query: "case-42"}
      ),
      LLMStub.tool_call_response(
        transport_name,
        {responsibility: "Finish case-42"}
      ),
      "Completed by target."
    ])

    result = Phronomy::MultiAgent::Runner.new(
      main_agent: source,
      handoffs: [handoff]
    ).invoke("ORIGINAL_CURRENT_REQUEST_MARKER: investigate case-42")

    expect(result[:agent]).to equal(target)
    expect(result[:output]).to eq("Completed by target.")
    expect(recorder.calls.length).to eq(3)

    target_text = recorder.last_messages
      .map { |message| message["content"] }
      .compact
      .join("\n")
    expect(target_text).to include("ORIGINAL_CURRENT_REQUEST_MARKER")
    expect(target_text).to include("lookup result for case-42")
  end
end
