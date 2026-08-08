# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::ContextImporter do
  it "preserves one imported logical message as one record" do
    call = RubyLLM::ToolCall.new(
      id: "call-1",
      name: "lookup",
      arguments: {q: "ruby"}
    )
    messages = [
      RubyLLM::Message.new(role: :user, content: "question"),
      RubyLLM::Message.new(
        role: :assistant,
        content: "checking",
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
      .to eq(%i[external_message assistant_message tool_message])

    assistant = context.records.fetch(1)
    expect(assistant.content).to include(
      "role" => "assistant",
      "content" => "checking"
    )
    expect(assistant.content.fetch("tool_calls").map { |value| value.fetch("id") })
      .to eq(["call-1"])
    expect(assistant.metadata.fetch("tool_call_ids")).to eq(["call-1"])

    tool = context.records.fetch(2)
    expect(tool.content).to eq(
      "role" => "tool",
      "content" => "answer",
      "tool_call_id" => "call-1"
    )
  end

  it "preserves assistant content and parallel Tool Calls inside one record" do
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
      %i[external_message assistant_message tool_message tool_message]
    )
    expect(context.records.fetch(1).content.fetch("tool_calls").map { |call| call.fetch("id") })
      .to contain_exactly("a", "b")
  end

  it "accepts distinct consecutive assistant messages exactly as supplied" do
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

    context = described_class.import_messages(messages)
    expect(context.records.map(&:kind))
      .to eq(%i[assistant_message assistant_message tool_message])
    expect(context.records.fetch(0).content.fetch("content")).to eq("first")
    expect(context.records.fetch(1).content.fetch("content")).to eq("")
    expect(context.records.fetch(1).content.fetch("tool_calls").length).to eq(1)
  end

  it "accepts multiple completed Tool rounds" do
    call_a = RubyLLM::ToolCall.new(id: "a", name: "one", arguments: {})
    call_b = RubyLLM::ToolCall.new(id: "b", name: "two", arguments: {})
    messages = [
      RubyLLM::Message.new(role: :assistant, content: "", tool_calls: {"a" => call_a}),
      RubyLLM::Message.new(role: :tool, content: "1", tool_call_id: "a"),
      RubyLLM::Message.new(role: :assistant, content: "", tool_calls: {"b" => call_b}),
      RubyLLM::Message.new(role: :tool, content: "2", tool_call_id: "b")
    ]

    context = described_class.import_messages(messages)
    expect(context.records.map(&:kind)).to eq(
      %i[assistant_message tool_message assistant_message tool_message]
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

  it "rejects duplicate Tool Call IDs" do
    call_a = RubyLLM::ToolCall.new(id: "same", name: "one", arguments: {})
    call_b = RubyLLM::ToolCall.new(id: "same", name: "two", arguments: {})
    messages = [
      RubyLLM::Message.new(role: :assistant, content: "", tool_calls: {"same" => call_a}),
      RubyLLM::Message.new(role: :tool, content: "1", tool_call_id: "same"),
      RubyLLM::Message.new(role: :assistant, content: "", tool_calls: {"same" => call_b}),
      RubyLLM::Message.new(role: :tool, content: "2", tool_call_id: "same")
    ]

    expect { described_class.import_messages(messages) }
      .to raise_error(ArgumentError, /duplicate tool_call id/)
  end

  it "rejects system messages instead of silently dropping them" do
    message = RubyLLM::Message.new(role: :system, content: "hidden")
    expect { described_class.import_messages([message]) }
      .to raise_error(ArgumentError, /explicit instruction segments/)
  end
end
