# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe "current Agent domain semantic payload codecs" do
  let(:root) do
    Phronomy::Agent::AgentRoot.create(
      agent_id: "codec-agent",
      agent_definition_id: "codec-agent-definition",
      agent_definition_version: 1,
      metadata: {"tenant" => "example"}
    )
  end

  let(:journal_record) do
    Phronomy::Agent::JournalRecord.new(
      record_id: "journal-1",
      agent_id: root.agent_id,
      sequence: 1,
      execution_id: "execution-1",
      kind: :external_message,
      channel: :external,
      role: :user,
      content_ref: "sha256:input",
      context_candidate: true,
      occurred_at: "2026-08-16T00:00:00.000000Z",
      metadata: {"source" => "test"}
    )
  end

  let(:llm_call) do
    Phronomy::Agent::LLMCallRecord.new(
      llm_call_id: "llm-1",
      execution_id: "execution-1",
      sequence: 1,
      status: :completed,
      manifest_ref: "sha256:manifest",
      output_ref: "sha256:output",
      completed_at: "2026-08-16T00:00:01.000000Z",
      metadata: {"model_id" => "test-model"}
    )
  end

  let(:approval_request) do
    {
      "id" => "approval-1",
      "execution_id" => "execution-1",
      "items" => [
        {
          "tool_invocation_id" => "tool-invocation-1",
          "tool_call_id" => "tool-call-1",
          "tool_name" => "protected_tool",
          "arguments" => {},
          "facts" => {},
          "reason" => nil,
          "origin" => "local",
          "metadata" => {}
        }
      ],
      "created_at" => "2026-08-16T00:00:01Z"
    }
  end

  let(:execution) do
    Phronomy::Agent::AgentExecution.new(
      execution_id: "execution-1",
      agent_id: root.agent_id,
      execution_revision: 3,
      status: :suspended,
      phase: :approval,
      base_agent_revision: 2,
      base_context_revision: 1,
      base_journal_position: 4,
      working_records: [journal_record],
      llm_calls: [llm_call],
      approval_request: approval_request,
      result_ref: nil,
      error_ref: nil,
      created_at: "2026-08-16T00:00:00.000000Z",
      updated_at: "2026-08-16T00:00:02.000000Z",
      terminal_reason: nil,
      metadata: {"fixture" => "codec-test"}
    )
  end

  it "writes and round-trips the canonical AgentRoot definition revision field" do
    expect(root.to_h["agent_definition_version"]).to eq(1)
    expect(root.to_h).not_to have_key("definition_version")
    expect(Phronomy::Agent::AgentRoot.from_h(root.to_h).to_h).to eq(root.to_h)
  end

  it "does not backward-decode the legacy AgentRoot definition_version key" do
    legacy = root.to_h
    legacy["definition_version"] =
      legacy.delete("agent_definition_version")

    expect do
      Phronomy::Agent::AgentRoot.from_h(legacy)
    end.to raise_error(KeyError, /agent_definition_version/)
  end

  it "keeps the current JournalRecord Hash payload symmetric" do
    expect(Phronomy::Agent::JournalRecord.from_h(journal_record.to_h).to_h)
      .to eq(journal_record.to_h)
  end

  it "rejects removed JournalRecord fields outside explicit migration" do
    legacy = journal_record.to_h.merge("correlation_id" => "legacy")

    expect do
      Phronomy::Agent::JournalRecord.from_h(legacy)
    end.to raise_error(ArgumentError, /unknown=.*correlation_id/)
  end

  it "round-trips AgentExecution including nested durable values" do
    restored = Phronomy::Agent::AgentExecution.from_h(execution.to_h)

    expect(restored.to_h).to eq(execution.to_h)
    expect(restored.working_records.first).to be_a(Phronomy::Agent::JournalRecord)
    expect(restored.llm_calls.first).to be_a(Phronomy::Agent::LLMCallRecord)
  end

  it "round-trips AgentExecution after JSON serialization" do
    parsed = JSON.parse(JSON.generate(execution.to_h))
    restored = Phronomy::Agent::AgentExecution.from_h(parsed)

    expect(restored.to_h).to eq(execution.to_h)
  end

  it "accepts Symbol top-level keys as current Ruby payload input" do
    symbolized = execution.to_h.transform_keys(&:to_sym)
    restored = Phronomy::Agent::AgentExecution.from_h(symbolized)

    expect(restored.to_h).to eq(execution.to_h)
  end

  it "rejects removed approval parent identity outside explicit migration" do
    legacy = execution.to_h
    approval = legacy.fetch("approval_request").dup
    approval["agent_invocation_id"] = approval.delete("execution_id")
    legacy["approval_request"] = approval

    restored = Phronomy::Agent::AgentExecution.from_h(legacy)
    expect(restored.approval_request).to have_key("agent_invocation_id")

    expect do
      Phronomy::Persistence::DurableCodec.encode_agent_execution(restored)
    end.to raise_error(Phronomy::Persistence::SerializationError, /approval_request.*schema mismatch/)
  end
end
