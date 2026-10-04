# frozen_string_literal: true

require "spec_helper"

RSpec.describe "LLM operation values" do
  [{:model => "one", "model" => "two"}, {1 => "invalid key"}, {"max_output_tokens" => 0}, {"max_output_tokens" => false}, {"model" => false},
    {"provider" => ""}, {"temperature" => "hot"}, {"cache_instructions" => 1}].each do |config|
    it "rejects invalid configuration #{config.inspect}" do
      expect { Phronomy::LLMAdapter::Request.new(model_config: config) }.to raise_error(ArgumentError)
    end
  end

  it "snapshots conversation values and round trips usage, Tool requests and opaque metadata" do
    args = {"nested" => [1]}
    call = Phronomy::Tool::CallRequest.new(id: "one", name: "lookup", arguments: args, metadata: {"thought_signature" => "opaque"})
    response = Phronomy::LLMAdapter::Response.new(tool_calls: [call], usage: Phronomy::LLMAdapter::TokenUsage.new(input: 0))
    messages = [response]
    request = Phronomy::LLMAdapter::Request.new(messages: messages)
    args["nested"] << 2
    messages.clear
    expect(request.messages.first.tool_calls.first.arguments).to eq("nested" => [1])
    restored = Phronomy::LLMAdapter::Response.from_h(response.to_h)
    expect(restored.to_h).to eq(response.to_h)
    expect(restored.usage.input).to eq(0)
    expect(restored.usage.output).to be_nil
    expect(restored.tool_calls.first.metadata).to eq("thought_signature" => "opaque")
    expect { call.arguments["nested"] << 3 }.to raise_error(FrozenError)
  end

  it "rejects duplicate Tool call identities and non-assistant results" do
    call = Phronomy::Tool::CallRequest.new(id: "one", name: "lookup", arguments: {})
    expect { Phronomy::LLMAdapter::Response.new(tool_calls: [call, call]) }.to raise_error(ArgumentError, /duplicate/)
    expect { Phronomy::LLMAdapter::Response.new(role: nil) }.to raise_error(ArgumentError, /assistant/)
    expect { Phronomy::LLMAdapter::Message.new(role: :user, tool_calls: [call]) }.to raise_error(ArgumentError, /assistant/)
    expect { Phronomy::LLMAdapter::Message.new(role: :tool) }.to raise_error(ArgumentError, /tool_call_id/)
  end
end
