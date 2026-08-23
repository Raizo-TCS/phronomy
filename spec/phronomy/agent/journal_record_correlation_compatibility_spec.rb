# frozen_string_literal: true

require "spec_helper"

RSpec.describe "CG-02b durable Journal correlation compatibility" do
  def build_record
    Phronomy::Agent::JournalRecord.new(
      record_id: "record-1",
      agent_id: "agent-1",
      sequence: 1,
      execution_id: "execution-1",
      llm_call_id: "llm-1",
      kind: :approval_required,
      channel: :approval,
      content_ref: "sha256:approval",
      context_generation: 0,
      context_candidate: false,
      occurred_at: "2026-08-23T00:00:00.000000Z",
      metadata: {"source" => "compatibility-test"}
    )
  end

  it "omits generic correlation from the canonical JournalRecord model and Hash" do
    record = build_record

    expect(Phronomy::Agent::JournalRecord::ATTRIBUTES)
      .not_to include(:correlation_id)
    expect(record).not_to respond_to(:correlation_id)
    expect(record.to_h).not_to have_key("correlation_id")
  end

  it "accepts and ignores a legacy durable correlation_id key" do
    legacy = build_record.to_h.merge(
      "correlation_id" => "legacy-correlation"
    )

    restored = Phronomy::Agent::JournalRecord.from_h(legacy)

    expect(restored).not_to respond_to(:correlation_id)
    expect(restored.to_h).not_to have_key("correlation_id")
    expect(restored.record_id).to eq("record-1")
    expect(restored.execution_id).to eq("execution-1")
    expect(restored.kind).to eq(:approval_required)
  end

  it "accepts legacy Journal records nested in a durable AgentExecution" do
    execution = Phronomy::Agent::AgentExecution.new(
      execution_id: "execution-1",
      agent_id: "agent-1",
      execution_revision: 2,
      status: :suspended,
      phase: :approval,
      base_agent_revision: 1,
      base_context_revision: 0,
      base_journal_position: 0,
      working_records: [build_record],
      llm_calls: [],
      approval_request: {
        "id" => "approval-1",
        "tool_name" => "protected_tool"
      },
      result_ref: nil,
      error_ref: nil,
      created_at: "2026-08-23T00:00:00.000000Z",
      updated_at: "2026-08-23T00:00:01.000000Z",
      terminal_reason: nil,
      metadata: {}
    )
    legacy = execution.to_h
    legacy.fetch("working_records").first["correlation_id"] =
      "legacy-correlation"

    restored = Phronomy::Agent::AgentExecution.from_h(legacy)
    restored_record = restored.working_records.first

    expect(restored_record).to be_a(Phronomy::Agent::JournalRecord)
    expect(restored_record).not_to respond_to(:correlation_id)
    expect(restored_record.to_h).not_to have_key("correlation_id")
    expect(restored_record.content_ref).to eq("sha256:approval")
  end
end
