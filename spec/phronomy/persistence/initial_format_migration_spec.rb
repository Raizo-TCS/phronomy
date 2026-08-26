# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Persistence::Migration::InitialFormatMigration do
  let(:root) do
    Phronomy::Agent::AgentRoot.create(
      agent_id: "migration-agent",
      agent_definition_id: "migration-definition",
      agent_definition_version: 1
    )
  end

  it "converts the fixed-base unversioned AgentRoot payload to v0.1" do
    record = described_class.agent_root(root.to_h)

    expect(record).to be_a(Phronomy::Persistence::DurableRecord)
    expect(record.record_type).to eq("phronomy.agent_root")
    expect(record.format_version).to eq("0.1")
    expect(Phronomy::Persistence::DurableCodec.decode_agent_root(record).agent_id)
      .to eq(root.agent_id)
  end

  it "isolates removed Journal correlation compatibility inside explicit migration" do
    current = Phronomy::Agent::JournalRecord.new(
      record_id: "record-1",
      agent_id: root.agent_id,
      sequence: 1,
      execution_id: "execution-1",
      llm_call_id: "llm-1",
      kind: :approval_required,
      channel: :approval,
      content_ref: "sha256:approval",
      context_generation: 0,
      context_candidate: false,
      occurred_at: "2026-08-23T00:00:00.000000Z",
      metadata: {"source" => "migration-test"}
    )
    legacy = current.to_h.merge("correlation_id" => "legacy-correlation")

    record = described_class.journal_record(legacy)
    restored = Phronomy::Persistence::DurableCodec.decode_journal_record(record)

    expect(restored.to_h).not_to have_key("correlation_id")
    expect(restored.record_id).to eq("record-1")
  end

  it "isolates the removed approval parent identity inside explicit migration" do
    working_record = Phronomy::Agent::JournalRecord.new(
      record_id: "record-1",
      agent_id: root.agent_id,
      sequence: 1,
      execution_id: "execution-1",
      kind: :approval_required,
      channel: :approval,
      content_ref: "sha256:approval"
    )
    execution = Phronomy::Agent::AgentExecution.new(
      execution_id: "execution-1",
      agent_id: root.agent_id,
      execution_revision: 2,
      status: :suspended,
      phase: :approval,
      base_agent_revision: 1,
      base_context_revision: 0,
      base_journal_position: 0,
      working_records: [working_record],
      llm_calls: [],
      approval_request: {
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
        "created_at" => "2026-08-23T00:00:00Z"
      },
      result_ref: nil,
      error_ref: nil,
      created_at: "2026-08-23T00:00:00.000000Z",
      updated_at: "2026-08-23T00:00:01.000000Z",
      terminal_reason: nil,
      metadata: {}
    )
    legacy = execution.to_h
    approval = legacy.fetch("approval_request").dup
    approval["agent_invocation_id"] = approval.delete("execution_id")
    legacy["approval_request"] = approval
    legacy.fetch("working_records").first["correlation_id"] = "legacy"

    record = described_class.agent_execution(legacy)
    restored = Phronomy::Persistence::DurableCodec.decode_agent_execution(record)

    expect(restored.approval_request).to include("execution_id" => "execution-1")
    expect(restored.approval_request).not_to have_key("agent_invocation_id")
    expect(restored.working_records.first.to_h).not_to have_key("correlation_id")
  end

  it "migrates the pre-CG-07 integer LLMInputManifest version explicitly" do
    old = {
      "version" => 1,
      "call_sequence" => 1,
      "call_mode" => "complete",
      "assembly_policy_version" => 1,
      "segments" => [],
      "model_config_ref" => "sha256:model"
    }

    migrated = described_class.llm_input_manifest(old)

    expect(migrated.fetch("version")).to eq("0.1")
    expect(Phronomy::Agent::LLMInputManifest.from_h(migrated).version).to eq("0.1")
  end
end
