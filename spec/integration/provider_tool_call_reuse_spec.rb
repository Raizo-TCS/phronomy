# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

RSpec.describe "Provider Tool call IDs across native response rounds", :integration do
  let(:effects) { [] }

  let(:agent_class) do
    recorded = effects
    tool = Class.new(Phronomy::Tool::Base) do
      tool_name "lookup"
      description "Look up a value"
      param :query, type: :string

      define_method(:execute) do |query:|
        recorded << query
        "found #{query}"
      end
    end
    IntegrationFactors.agent_class("base", tools: [tool])
  end

  after { LLMStub.deactivate }

  def lookup(query)
    {
      "id" => "response-#{query}", "model" => "stub-model", "object" => "chat.completion",
      "choices" => [{
        "index" => 0, "finish_reason" => "tool_calls",
        "message" => {"role" => "assistant", "tool_calls" => [{
          "id" => "call_0", "type" => "function",
          "function" => {"name" => "lookup", "arguments" => JSON.generate(query: query)}
        }]}
      }]
    }
  end

  def expect_exchanges(messages)
    exchanges = messages.filter_map do |message|
      if message["tool_calls"]
        call = message.fetch("tool_calls").fetch(0)
        [call.fetch("id"), JSON.parse(call.fetch("function").fetch("arguments")).fetch("query")]
      elsif message["role"] == "tool"
        [message.fetch("tool_call_id"), message.fetch("content")]
      end
    end
    expect(exchanges).to eq([["call_0", "alpha"], ["call_0", "found alpha"],
      ["call_0", "beta"], ["call_0", "found beta"]])
    expect(effects).to eq(%w[alpha beta])
  end

  it "retains the right arguments, results, and original IDs across two rounds in one Execution" do
    llm = LLMStub.activate(responses: [lookup("alpha"), lookup("beta"), "done"])
    expect(agent_class.new.invoke("look up both").fetch(:output)).to eq("done")
    expect(llm.calls.length).to eq(3)
    expect_exchanges(llm.last_messages)
  end

  it "retains both exchanges when a reloaded Agent runs a second Execution" do
    llm = LLMStub.activate(responses: [lookup("alpha"), "first", lookup("beta"), "second"])
    agent = agent_class.new
    expect(agent.invoke("look up alpha").fetch(:output)).to eq("first")
    id, store = agent.agent_id, agent.persistence
    agent.unload!
    reloaded = agent_class.load(id, persistence: store)
    expect(reloaded.invoke("look up beta").fetch(:output)).to eq("second")
    expect(llm.calls.length).to eq(4)
    expect_exchanges(llm.last_messages)
  end
end
