# frozen_string_literal: true

require "spec_helper"
require_relative "../../integration/support/llm_stub"

RSpec.describe Phronomy::Agent::HandoffRunner do
  let(:store) { Phronomy::Persistence::InMemory.new }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "runner-unit", version: 1
      model "gpt-4o-mini"
      provider :openai
    end
  end
  before do
    RubyLLM.configure { |c|
      c.openai_api_key = "test"
      c.openai_api_base = "https://example.test/v1"
    }
    Phronomy.configure { |c| c.default_output_reserve = 4096 }
  end
  after { LLMStub.deactivate }

  it "returns the durable result and active Agent without internal transport fields" do
    main = agent_class.create(persistence: store)
    LLMStub.activate(responses: ["direct answer"])
    result = described_class.new(main_agent: main).invoke("question")
    expect(result[:output]).to eq("direct answer")
    expect(result[:agent]).to equal(main)
    expect(result.keys.grep(/phronomy_handoff/)).to be_empty
    expect(result).not_to have_key(:handoff_request)
    expect(store.executions.load(result[:execution_id]).status).to eq(:completed)
  end

  it "bounds a cyclic graph without discarding the last committed responsibility" do
    source = agent_class.create(persistence: store)
    target = agent_class.create(persistence: store)
    edge = Phronomy::Agent::Handoff.new(source_agent: source, target_agent: target)
    reverse = Phronomy::Agent::Handoff.new(source_agent: target, target_agent: source)
    names = [edge, reverse].map { |h| Phronomy::Agent::HandoffCapabilityFactory.build(h).tool_name }
    stub_const("Phronomy::Agent::HandoffRunner::MAX_HANDOFFS", 1)
    LLMStub.activate(responses: names.map { |name| LLMStub.tool_call_response(name, {responsibility: "continue"}) })
    expect do
      described_class.new(main_agent: source, handoffs: [edge, reverse]).invoke("ping")
    end.to raise_error(Phronomy::HandoffError, /Exceeded maximum Handoffs/)
    routing = store.handoff_states.load(source.agent_id)
    expect(routing.active_agent_id).to eq(source.agent_id)
    expect(routing.phase).to eq("target_pending")
  end
end
