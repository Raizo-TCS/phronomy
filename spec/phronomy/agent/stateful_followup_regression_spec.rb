# frozen_string_literal: true

require "spec_helper"

RSpec.describe "stateful manifest follow-up regressions" do
  it "rejects an invalid before_llm_input return value" do
    klass = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "invalid-hook-result", version: 1
      before_llm_input ->(_context) { {} }
    end
    expect {
      klass.new.send(:run_before_llm_input_hooks, call_sequence: 1, config: {})
    }.to raise_error(TypeError, /LLMInputPatch/)
  end

  it "deep-copies hook config" do
    config = {nested: {value: 1}}
    context = Phronomy::Agent::LLMInputBuildContext.new(
      agent_id: "a", agent_definition_id: "d", definition_version: 1,
      config: config, call_sequence: 1
    )
    config[:nested][:value] = 2
    expect(context.config[:nested][:value]).to eq(1)
  end

  it "requires a valid output reserve for an explicit context window" do
    agent = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "budget-agent", version: 1
    end.new
    expect {
      Phronomy::Agent::TokenBudgetResolver.new(agent: agent).resolve(
        "model" => "local", "context_window" => 1024
      )
    }.to raise_error(Phronomy::InvalidContextBudgetConfigurationError)
  end
end
