# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"

# Verifies the Phronomy side of the transport-policy ownership contract.
# RubyLLM may perform its own configured retries internally. Once the adapter
# returns a final success or error, Phronomy must not replay AgentInvocation.
RSpec.describe "LLM transport policy delegation", :integration do
  def stub_chat_setup
    allow_any_instance_of(RubyLLM::Chat).to receive(:with_instructions).and_return(nil)
    allow_any_instance_of(RubyLLM::Chat).to receive(:messages).and_return([])
  end

  it "translates a final RubyLLM rate-limit error without starting another LLM call" do
    stub_chat_setup
    calls = 0
    allow_any_instance_of(RubyLLM::Chat).to receive(:ask) do
      calls += 1
      raise RubyLLM::RateLimitError, "final rate-limit error"
    end

    agent = IntegrationFactors.agent_class("base").new

    expect { agent.invoke("hello") }.to raise_error(Phronomy::RateLimitError)
    expect(calls).to eq(1)
  end

  it "returns a successful response after one adapter call" do
    stub_chat_setup
    calls = 0
    response = IntegrationFactors.fake_llm_response(content: "ok")
    allow_any_instance_of(RubyLLM::Chat).to receive(:ask) do
      calls += 1
      response
    end

    result = IntegrationFactors.agent_class("base").new.invoke("hello")

    expect(result[:output]).to eq("ok")
    expect(calls).to eq(1)
  end
end
