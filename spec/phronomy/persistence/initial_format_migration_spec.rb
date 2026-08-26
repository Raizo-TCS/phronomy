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

  def build_execution_without_approval
    Phronomy::Agent::AgentExecution.new(
      execution_id: "exec-migration-1",
      agent_id: root.agent_id,
      execution_revision: 1,
      status: :active,
      phase: :calling_llm,
      base_agent_revision: 0,
      base_context_revision: 0,
      base_journal_position: 0,
      working_records: [],
      llm_calls: [],
      approval_request: nil,
      result_ref: nil,
      error_ref: nil,
      created_at: "2026-08-26T00:00:00.000000Z",
      updated_at: "2026-08-26T00:00:01.000000Z",
      terminal_reason: nil,
      metadata: {}
    )
  end

  def build_execution_with_approval
    Phronomy::Agent::AgentExecution.new(
      execution_id: "exec-migration-2",
      agent_id: root.agent_id,
      execution_revision: 2,
      status: :suspended,
      phase: :approval,
      base_agent_revision: 0,
      base_context_revision: 0,
      base_journal_position: 0,
      working_records: [],
      llm_calls: [],
      approval_request: {
        "id" => "approval-migration-1",
        "execution_id" => "exec-migration-2",
        "items" => [
          {
            "tool_invocation_id" => "tv-1",
            "tool_call_id" => "tc-1",
            "tool_name" => "protected_tool",
            "arguments" => {},
            "facts" => {},
            "reason" => nil,
            "origin" => "local",
            "metadata" => {}
          }
        ],
        "created_at" => "2026-08-26T00:00:00Z"
      },
      result_ref: nil,
      error_ref: nil,
      created_at: "2026-08-26T00:00:00.000000Z",
      updated_at: "2026-08-26T00:00:01.000000Z",
      terminal_reason: nil,
      metadata: {}
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

  it "rejects unknown pre-S3 AgentRoot fields instead of silently dropping them" do
    legacy = root.to_h.merge("unknown_legacy_field" => true)

    expect do
      described_class.agent_root(legacy)
    end.to raise_error(
      Phronomy::Persistence::SerializationError,
      /pre-S3 AgentRoot.*unknown=.*unknown_legacy_field/
    )
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

  it "rejects unknown pre-S3 Journal fields other than the known correlation field" do
    current = Phronomy::Agent::JournalRecord.new(
      record_id: "record-1",
      agent_id: root.agent_id,
      sequence: 1,
      kind: :knowledge,
      channel: :context
    )

    expect do
      described_class.journal_record(current.to_h.merge("mystery" => 1))
    end.to raise_error(
      Phronomy::Persistence::SerializationError,
      /pre-S3 JournalRecord.*unknown=.*mystery/
    )
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

  it "rejects unknown nested pre-S3 AgentExecution fields" do
    execution = Phronomy::Agent::AgentExecution.new(
      execution_id: "execution-1",
      agent_id: root.agent_id,
      execution_revision: 0,
      status: :active,
      phase: :calling_llm,
      base_agent_revision: 0,
      base_context_revision: 0,
      base_journal_position: 0,
      working_records: [],
      llm_calls: [],
      approval_request: nil,
      result_ref: nil,
      error_ref: nil,
      created_at: "2026-08-23T00:00:00.000000Z",
      updated_at: "2026-08-23T00:00:01.000000Z",
      terminal_reason: nil,
      metadata: {}
    )
    legacy = execution.to_h
    legacy["llm_calls"] = [
      {
        "llm_call_id" => "llm-1",
        "execution_id" => "execution-1",
        "sequence" => 1,
        "status" => "completed",
        "manifest_ref" => "sha256:m",
        "output_ref" => nil,
        "error_ref" => nil,
        "usage_ref" => nil,
        "started_at" => "2026-08-23T00:00:00Z",
        "completed_at" => "2026-08-23T00:00:01Z",
        "metadata" => {},
        "mystery" => true
      }
    ]

    expect do
      described_class.agent_execution(legacy)
    end.to raise_error(
      Phronomy::Persistence::SerializationError,
      /llm_calls\[0\].*unknown=.*mystery/
    )
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

  it "rejects an unsupported pre-S3 LLMInputManifest version" do
    unsupported = {
      "version" => "2",
      "call_sequence" => 1,
      "call_mode" => "complete",
      "assembly_policy_version" => 1,
      "segments" => [],
      "model_config_ref" => "sha256:model"
    }

    expect do
      described_class.llm_input_manifest(unsupported)
    end.to raise_error(
      Phronomy::Persistence::SerializationError,
      /unsupported pre-S3 LLMInputManifest version/
    )
  end

  it "rejects a non-Hash migration input" do
    expect do
      described_class.agent_root("not-a-hash")
    end.to raise_error(Phronomy::Persistence::SerializationError, /must be a Hash/)
  end

  it "rejects a migration input with non-String/Symbol keys" do
    expect do
      described_class.agent_root({123 => "value"})
    end.to raise_error(Phronomy::Persistence::SerializationError, /key must be String or Symbol/)
  end

  it "rejects a migration input with duplicate keys after normalization" do
    # :foo and "foo" both normalize to "foo" → duplicate
    mixed = {foo: "a"}.merge("foo" => "b")
    expect do
      described_class.agent_root(mixed)
    end.to raise_error(Phronomy::Persistence::SerializationError, /duplicate/)
  end

  it "returns nil for a nil approval_request in agent_execution migration" do
    legacy = build_execution_without_approval.to_h
    record = described_class.agent_execution(legacy)
    restored = Phronomy::Persistence::DurableCodec.decode_agent_execution(record)
    expect(restored.approval_request).to be_nil
  end

  it "rejects an approval_request where execution_id does not match the enclosing execution" do
    execution = build_execution_with_approval
    legacy = execution.to_h
    approval = legacy.fetch("approval_request").dup
    approval.delete("agent_invocation_id")
    approval["execution_id"] = "different-execution-id"
    legacy["approval_request"] = approval

    expect do
      described_class.agent_execution(legacy)
    end.to raise_error(
      Phronomy::Persistence::SerializationError,
      /execution_id does not match/
    )
  end

  it "rejects an approval_request with empty items" do
    execution = build_execution_with_approval
    legacy = execution.to_h
    approval = legacy.fetch("approval_request").dup
    approval.delete("agent_invocation_id")
    approval["execution_id"] = execution.execution_id
    approval["items"] = []
    legacy["approval_request"] = approval

    expect do
      described_class.agent_execution(legacy)
    end.to raise_error(
      Phronomy::Persistence::SerializationError,
      /items must be a non-empty Array/
    )
  end
end
