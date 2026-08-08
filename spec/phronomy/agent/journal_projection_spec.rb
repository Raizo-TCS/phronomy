# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::JournalProjection do
  it "derives transcript from the current generation of the Journal" do
    persistence = Phronomy::Persistence::InMemory.new
    root = Phronomy::Agent::AgentRoot.create(
      agent_id: "agent-1",
      agent_definition_id: "test-agent",
      definition_version: 1
    )
    old_ref = persistence.contents.put_text("old")
    current_ref = persistence.contents.put_text("current")
    records = [
      Phronomy::Agent::JournalRecord.new(
        agent_id: root.agent_id,
        kind: :external_message,
        channel: :external,
        role: :user,
        content_ref: old_ref,
        context_generation: 0,
        context_candidate: true
      ),
      Phronomy::Agent::JournalRecord.new(
        agent_id: root.agent_id,
        kind: :external_message,
        channel: :external,
        role: :user,
        content_ref: current_ref,
        context_generation: 1,
        context_candidate: true
      )
    ]
    persistence.transaction do |tx|
      tx.agents.create(root)
      appended = tx.journals.append(root.agent_id, expected_position: 0, records: records)
      root = root.with(
        agent_revision: 1,
        context_revision: 1,
        journal_position: appended.length,
        transcript_generation: 1
      )
      tx.agents.save(root.agent_id, expected_revision: 0, root: root)
    end

    projection = described_class.new(persistence: persistence, agent_root: root)
    expect(projection.transcript_records.map(&:content_ref)).to eq([current_ref])
  end

  it "includes canonical assistant/tool messages but not raw Tool results" do
    persistence = Phronomy::Persistence::InMemory.new
    root = Phronomy::Agent::AgentRoot.create(
      agent_id: "agent-1",
      agent_definition_id: "test-agent",
      definition_version: 1
    )
    assistant_ref = persistence.contents.put_json(
      "role" => "assistant", "content" => "checking", "tool_calls" => []
    )
    tool_message_ref = persistence.contents.put_json(
      "role" => "tool", "content" => "visible", "tool_call_id" => "a"
    )
    raw_result_ref = persistence.contents.put_json("value" => 1)
    records = [
      Phronomy::Agent::JournalRecord.new(
        agent_id: root.agent_id,
        kind: :assistant_message,
        channel: :llm,
        role: :assistant,
        content_ref: assistant_ref,
        context_generation: 0,
        context_candidate: true
      ),
      Phronomy::Agent::JournalRecord.new(
        agent_id: root.agent_id,
        kind: :tool_result,
        channel: :tool,
        content_ref: raw_result_ref,
        context_generation: 0,
        context_candidate: false,
        metadata: {"tool_call_id" => "a"}
      ),
      Phronomy::Agent::JournalRecord.new(
        agent_id: root.agent_id,
        kind: :tool_message,
        channel: :tool,
        role: :tool,
        content_ref: tool_message_ref,
        context_generation: 0,
        context_candidate: true,
        metadata: {"tool_call_id" => "a"}
      )
    ]
    persistence.transaction do |tx|
      tx.agents.create(root)
      appended = tx.journals.append(root.agent_id, expected_position: 0, records: records)
      root = root.with(agent_revision: 1, context_revision: 1, journal_position: appended.length)
      tx.agents.save(root.agent_id, expected_revision: 0, root: root)
    end

    projection = described_class.new(persistence: persistence, agent_root: root)
    expect(projection.transcript_records.map(&:kind))
      .to eq(%i[assistant_message tool_message])
  end
end
