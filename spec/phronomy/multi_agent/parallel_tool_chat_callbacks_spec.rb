# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::MultiAgent::ParallelToolChat do
  it "dispatches RubyLLM 1.15 additive Tool callbacks on the direct parallel fallback" do
    chat = described_class.new
    tool_a = double("tool-a")
    tool_b = double("tool-b")
    allow(tool_a).to receive(:call).and_return("a-result")
    allow(tool_b).to receive(:call).and_return("b-result")
    chat.instance_variable_set(:@tools, {a: tool_a, b: tool_b})

    call_a = RubyLLM::ToolCall.new(id: "a", name: "a", arguments: {})
    call_b = RubyLLM::ToolCall.new(id: "b", name: "b", arguments: {})
    response = double("response", tool_calls: {"a" => call_a, "b" => call_b})

    before_calls = []
    after_results = []
    chat.before_tool_call { |tool_call| before_calls << tool_call.id }
    chat.after_tool_result { |result| after_results << result }

    allow(Phronomy::Agent::ToolExecutor).to receive(:call_async) do |tool:, args:, cancellation_token:|
      result = tool.call(args)
      double("awaitable", wait_result: result)
    end
    allow(chat).to receive(:forced_tool_choice?).and_return(false)
    allow(chat).to receive(:complete).and_return(nil)

    chat.send(:handle_tool_calls, response)

    expect(before_calls).to eq(%w[a b])
    expect(after_results).to eq(%w[a-result b-result])
  end
end
