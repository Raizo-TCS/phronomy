# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::RubyLLMMaterializer do
  it "reconstructs Tool Call and Tool result messages with causation IDs" do
    persistence = Phronomy::Persistence::InMemory.new
    tool_call_ref = persistence.contents.put_json(
      "id" => "call-1",
      "name" => "lookup",
      "arguments" => {"q" => "ruby"}
    )
    tool_result_ref = persistence.contents.put_text("found")

    agent_class = Class.new do
      def self.tools = []
    end
    agent = Object.new
    agent.define_singleton_method(:class) { agent_class }
    agent.define_singleton_method(:_handoff_tools) { [] }

    materializer = described_class.new(agent: agent, persistence: persistence)
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
end
