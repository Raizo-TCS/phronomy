# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

RSpec.describe "Multi-Agent Handoff", :integration do
  after { LLMStub.deactivate }

  def build_agent(definition_id, instructions)
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: definition_id, version: 1
      model IntegrationFactors::LM_MODEL_26
      provider :openai
      instructions instructions
    end.new
  end

  it "runs the main Agent when no Handoff is requested" do
    main = build_agent("cg05-main-no-handoff", "Main agent")
    LLMStub.activate(responses: ["Handled by main."])

    runner = Phronomy::MultiAgent::Runner.new(main_agent: main)
    result = runner.invoke("Hello")

    expect(result[:output]).to eq("Handled by main.")
    expect(result[:agent]).to equal(main)
  end

  it "transfers responsibility without a sentinel Tool result" do
    source = build_agent("cg05-source-once", "Triage agent")
    target = build_agent("cg05-target-once", "Billing agent")
    handoff = Phronomy::MultiAgent::Handoff.new(
      source_agent: source,
      target_agent: target,
      description: "Transfer billing responsibility"
    )
    transport_name = Phronomy::MultiAgent::HandoffCapabilityFactory.build(handoff).tool_name

    LLMStub.activate(responses: [
      LLMStub.tool_call_response(
        transport_name,
        {responsibility: "Investigate the billing discrepancy"}
      ),
      "Billing investigation complete."
    ])

    runner = Phronomy::MultiAgent::Runner.new(
      main_agent: source,
      handoffs: [handoff]
    )
    result = runner.invoke("My invoice is wrong.")

    expect(result[:output]).to eq("Billing investigation complete.")
    expect(result[:agent]).to equal(target)
    expect(result).not_to have_key(:handoff_request)
    expect(result.keys.grep(/phronomy_handoff/)).to be_empty
  end

  it "keeps the Target active for the next user turn in the same Runtime" do
    source = build_agent("cg05-source-continuity", "Triage agent")
    target = build_agent("cg05-target-continuity", "Billing agent")
    handoff = Phronomy::MultiAgent::Handoff.new(
      source_agent: source,
      target_agent: target
    )
    transport_name = Phronomy::MultiAgent::HandoffCapabilityFactory.build(handoff).tool_name

    LLMStub.activate(responses: [
      LLMStub.tool_call_response(
        transport_name,
        {responsibility: "Own the billing case"}
      ),
      "First billing answer.",
      "Second billing answer."
    ])

    runner = Phronomy::MultiAgent::Runner.new(
      main_agent: source,
      handoffs: [handoff]
    )

    first = runner.invoke("I have a billing problem.")
    second = runner.invoke("I have another detail.")

    expect(first[:agent]).to equal(target)
    expect(second[:agent]).to equal(target)
    expect(second[:output]).to eq("Second billing answer.")
  end

  it "preserves the active Agent when only the Runner facade is recreated" do
    source = build_agent("cg05-source-recreate", "Triage agent")
    target = build_agent("cg05-target-recreate", "Billing agent")
    handoff = Phronomy::MultiAgent::Handoff.new(
      source_agent: source,
      target_agent: target
    )
    transport_name = Phronomy::MultiAgent::HandoffCapabilityFactory.build(handoff).tool_name

    LLMStub.activate(responses: [
      LLMStub.tool_call_response(
        transport_name,
        {responsibility: "Own the billing case"}
      ),
      "First billing answer.",
      "Continued by billing."
    ])

    Phronomy::MultiAgent::Runner.new(
      main_agent: source,
      handoffs: [handoff]
    ).invoke("Start")

    recreated = Phronomy::MultiAgent::Runner.new(
      main_agent: source,
      handoffs: [handoff]
    )
    result = recreated.invoke("Continue")

    expect(result[:agent]).to equal(target)
    expect(result[:output]).to eq("Continued by billing.")
  end
end
