# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::ContextImporter do
  it "imports user, assistant Tool Call, and Tool result as typed records" do
    call = RubyLLM::ToolCall.new(
      id: "call-1",
      name: "lookup",
      arguments: {q: "ruby"}
    )
    messages = [
      RubyLLM::Message.new(role: :user, content: "question"),
      RubyLLM::Message.new(
        role: :assistant,
        content: "",
        tool_calls: {"call-1" => call}
      ),
      RubyLLM::Message.new(
        role: :tool,
        content: "answer",
        tool_call_id: "call-1"
      )
    ]

    context = described_class.import_messages(messages)
    expect(context.records.map(&:kind))
      .to eq(%i[external_message tool_call tool_result])
    expect(context.records.last.metadata.fetch("tool_call_id")).to eq("call-1")
  end

  it "rejects system messages instead of silently dropping them" do
    message = RubyLLM::Message.new(role: :system, content: "hidden")
    expect { described_class.import_messages([message]) }
      .to raise_error(ArgumentError, /explicit instruction segments/)
  end
end
