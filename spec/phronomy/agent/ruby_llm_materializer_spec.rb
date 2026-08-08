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

  it "reconstructs Tool Call and Tool result messages with causation IDs" do
    tool_call_ref = persistence.contents.put_json(
      "id" => "call-1",
      "name" => "lookup",
      "arguments" => {"q" => "ruby"}
    )
    tool_result_ref = persistence.contents.put_text("found")

    call_record = Phronomy::Agent::JournalRecord.new(
      agent_id: "agent-1",
      kind: :tool_call,
      channel: :tool,
      role: :assistant,
      content_ref: tool_call_ref,
      metadata: {"tool_call_id" => "call-1"}
    )
    result_record = Phronomy::Agent::JournalRecord.new(
      agent_id: "agent-1",
      kind: :tool_result,
      channel: :tool,
      role: :tool,
      content_ref: tool_result_ref,
      metadata: {"tool_call_id" => "call-1"}
    )

    call_message = materializer.materialize_journal_record(call_record)
    result_message = materializer.materialize_journal_record(result_record)
    expect(call_message.tool_calls.fetch("call-1").name).to eq("lookup")
    expect(result_message.tool_call_id).to eq("call-1")
  end

  it "aggregates assistant text and parallel Tool Calls from one runtime llm_call_id" do
    text_ref = persistence.contents.put_text("I will check both")
    call_a_ref = persistence.contents.put_json(
      "id" => "a", "name" => "one", "arguments" => {}
    )
    call_b_ref = persistence.contents.put_json(
      "id" => "b", "name" => "two", "arguments" => {}
    )
    result_a_ref = persistence.contents.put_text("1")
    result_b_ref = persistence.contents.put_text("2")

    records = [
      Phronomy::Agent::JournalRecord.new(
        agent_id: "agent-1", sequence: 1, llm_call_id: "llm-1",
        kind: :llm_message, channel: :llm, role: :assistant,
        content_ref: text_ref
      ),
      Phronomy::Agent::JournalRecord.new(
        agent_id: "agent-1", sequence: 2, llm_call_id: "llm-1",
        kind: :tool_call, channel: :tool, role: :assistant,
        content_ref: call_a_ref, metadata: {"tool_call_id" => "a"}
      ),
      Phronomy::Agent::JournalRecord.new(
        agent_id: "agent-1", sequence: 3, llm_call_id: "llm-1",
        kind: :tool_call, channel: :tool, role: :assistant,
        content_ref: call_b_ref, metadata: {"tool_call_id" => "b"}
      ),
      Phronomy::Agent::JournalRecord.new(
        agent_id: "agent-1", sequence: 4, llm_call_id: "llm-1",
        kind: :tool_result, channel: :tool, role: :tool,
        content_ref: result_a_ref, metadata: {"tool_call_id" => "a"}
      ),
      Phronomy::Agent::JournalRecord.new(
        agent_id: "agent-1", sequence: 5, llm_call_id: "llm-1",
        kind: :tool_result, channel: :tool, role: :tool,
        content_ref: result_b_ref, metadata: {"tool_call_id" => "b"}
      )
    ]

    messages = materializer.materialize_journal_records(records)
    expect(messages.length).to eq(3)
    expect(messages.first.role).to eq(:assistant)
    expect(messages.first.content.to_s).to eq("I will check both")
    expect(messages.first.tool_calls.keys).to contain_exactly("a", "b")
    expect(messages.drop(1).map(&:tool_call_id)).to eq(%w[a b])
  end

  it "uses canonical sequence rather than synthetic IDs for imported Tool batches" do
    text_ref = persistence.contents.put_text("checking")
    call_ref = persistence.contents.put_json(
      "id" => "a", "name" => "one", "arguments" => {}
    )
    result_ref = persistence.contents.put_text("1")

    records = [
      Phronomy::Agent::JournalRecord.new(
        agent_id: "agent-1", sequence: 10,
        kind: :llm_message, channel: :llm, role: :assistant,
        content_ref: text_ref
      ),
      Phronomy::Agent::JournalRecord.new(
        agent_id: "agent-1", sequence: 11,
        kind: :tool_call, channel: :tool, role: :assistant,
        content_ref: call_ref, metadata: {"tool_call_id" => "a"}
      ),
      Phronomy::Agent::JournalRecord.new(
        agent_id: "agent-1", sequence: 12,
        kind: :tool_result, channel: :tool, role: :tool,
        content_ref: result_ref, metadata: {"tool_call_id" => "a"}
      )
    ]

    messages = materializer.materialize_journal_records(records)
    expect(messages.length).to eq(2)
    expect(messages.first.content.to_s).to eq("checking")
    expect(messages.first.tool_calls.keys).to eq(["a"])
  end
end
