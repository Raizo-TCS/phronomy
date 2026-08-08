# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::RubyLLMMaterializer do
  let(:persistence) { Phronomy::Persistence::InMemory.new }
  let(:agent) do
    agent_class = Class.new do
      def self.tools = []
    end
    Object.new.tap do |value|
      value.define_singleton_method(:class) { agent_class }
      value.define_singleton_method(:_handoff_tools) { [] }
    end
  end
  let(:materializer) { described_class.new(agent: agent, persistence: persistence) }

  it "materializes one canonical assistant record without reconstructing message boundaries" do
    assistant_ref = persistence.contents.put_json(
      "role" => "assistant",
      "content" => "I will check both",
      "tool_calls" => [
        {"id" => "a", "name" => "one", "arguments" => {}},
        {"id" => "b", "name" => "two", "arguments" => {}}
      ]
    )
    record = Phronomy::Agent::JournalRecord.new(
      agent_id: "agent-1",
      sequence: 1,
      llm_call_id: "llm-1",
      kind: :assistant_message,
      channel: :llm,
      role: :assistant,
      content_ref: assistant_ref,
      metadata: {"tool_call_ids" => %w[a b]}
    )

    message = materializer.materialize_journal_record(record)
    expect(message.role).to eq(:assistant)
    expect(message.content).to eq("I will check both")
    expect(message.tool_calls.keys).to contain_exactly("a", "b")
  end

  it "materializes canonical Tool messages exactly as recorded" do
    tool_ref = persistence.contents.put_json(
      "role" => "tool",
      "content" => "{:price=>100}",
      "tool_call_id" => "price-call"
    )
    record = Phronomy::Agent::JournalRecord.new(
      agent_id: "agent-1",
      sequence: 2,
      kind: :tool_message,
      channel: :tool,
      role: :tool,
      content_ref: tool_ref,
      metadata: {"tool_call_id" => "price-call"}
    )

    message = materializer.materialize_journal_record(record)
    expect(message.role).to eq(:tool)
    expect(message.content).to eq("{:price=>100}")
    expect(message.tool_call_id).to eq("price-call")
  end

  it "preserves distinct imported assistant message boundaries" do
    first_ref = persistence.contents.put_json(
      "role" => "assistant",
      "content" => "first",
      "tool_calls" => []
    )
    second_ref = persistence.contents.put_json(
      "role" => "assistant",
      "content" => "",
      "tool_calls" => [
        {"id" => "a", "name" => "one", "arguments" => {}}
      ]
    )
    result_ref = persistence.contents.put_json(
      "role" => "tool",
      "content" => "1",
      "tool_call_id" => "a"
    )

    records = [
      Phronomy::Agent::JournalRecord.new(
        agent_id: "agent-1", sequence: 10,
        kind: :assistant_message, channel: :llm, role: :assistant,
        content_ref: first_ref, metadata: {"tool_call_ids" => []}
      ),
      Phronomy::Agent::JournalRecord.new(
        agent_id: "agent-1", sequence: 11,
        kind: :assistant_message, channel: :llm, role: :assistant,
        content_ref: second_ref, metadata: {"tool_call_ids" => ["a"]}
      ),
      Phronomy::Agent::JournalRecord.new(
        agent_id: "agent-1", sequence: 12,
        kind: :tool_message, channel: :tool, role: :tool,
        content_ref: result_ref, metadata: {"tool_call_id" => "a"}
      )
    ]

    messages = materializer.materialize_journal_records(records)
    expect(messages.length).to eq(3)
    expect(messages.fetch(0).content).to eq("first")
    expect(messages.fetch(0).tool_calls).to be_nil
    expect(messages.fetch(1).tool_calls.keys).to eq(["a"])
    expect(messages.fetch(2).tool_call_id).to eq("a")
  end

  it "preserves structured canonical assistant content" do
    assistant_ref = persistence.contents.put_json(
      "role" => "assistant",
      "content" => {"answer" => 42},
      "tool_calls" => []
    )
    record = Phronomy::Agent::JournalRecord.new(
      agent_id: "agent-1",
      kind: :assistant_message,
      channel: :llm,
      role: :assistant,
      content_ref: assistant_ref
    )

    message = materializer.materialize_journal_record(record)
    expect(message.content).to eq("answer" => 42)
  end
end
