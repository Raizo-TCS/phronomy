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

  it "preserves assistant content before all parallel Tool Calls" do
    call_a = RubyLLM::ToolCall.new(id: "a", name: "one", arguments: {})
    call_b = RubyLLM::ToolCall.new(id: "b", name: "two", arguments: {})
    messages = [
      RubyLLM::Message.new(role: :user, content: "question"),
      RubyLLM::Message.new(
        role: :assistant,
        content: "working",
        tool_calls: {"a" => call_a, "b" => call_b}
      ),
      RubyLLM::Message.new(role: :tool, content: "1", tool_call_id: "a"),
      RubyLLM::Message.new(role: :tool, content: "2", tool_call_id: "b")
    ]

    context = described_class.import_messages(messages)
    expect(context.records.map(&:kind)).to eq(
      %i[external_message llm_message tool_call tool_call tool_result tool_result]
    )
  end

  it "rejects orphan Tool Results" do
    message = RubyLLM::Message.new(
      role: :tool,
      content: "answer",
      tool_call_id: "missing"
    )

    expect { described_class.import_messages([message]) }
      .to raise_error(ArgumentError, /orphan or duplicate Tool Result/)
  end

  it "rejects unresolved Tool Calls" do
    call = RubyLLM::ToolCall.new(id: "call-1", name: "lookup", arguments: {})
    messages = [
      RubyLLM::Message.new(
        role: :assistant,
        content: "",
        tool_calls: {"call-1" => call}
      )
    ]

    expect { described_class.import_messages(messages) }
      .to raise_error(ArgumentError, /ends before Tool Results/)
  end

  it "rejects a tool-call-only assistant message whose flattened boundary is ambiguous" do
    call = RubyLLM::ToolCall.new(id: "call-1", name: "lookup", arguments: {})
    messages = [
      RubyLLM::Message.new(role: :assistant, content: "first"),
      RubyLLM::Message.new(
        role: :assistant,
        content: "",
        tool_calls: {"call-1" => call}
      ),
      RubyLLM::Message.new(role: :tool, content: "answer", tool_call_id: "call-1")
    ]

    expect { described_class.import_messages(messages) }
      .to raise_error(ArgumentError, /tool-call-only assistant message/)
  end

  it "allows consecutive assistant text messages when the boundary remains explicit" do
    messages = [
      RubyLLM::Message.new(role: :assistant, content: "first"),
      RubyLLM::Message.new(role: :assistant, content: "second")
    ]

    context = described_class.import_messages(messages)
    expect(context.records.map(&:kind)).to eq(%i[llm_message llm_message])
  end

  it "rejects system messages instead of silently dropping them" do
    message = RubyLLM::Message.new(role: :system, content: "hidden")
    expect { described_class.import_messages([message]) }
      .to raise_error(ArgumentError, /explicit instruction segments/)
  end
end
