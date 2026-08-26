# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Persistence::DurableCodec do
  let(:root) do
    Phronomy::Agent::AgentRoot.create(
      agent_id: "codec-agent",
      agent_definition_id: "codec-definition",
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
      llm_call_id: "llm-1",
      kind: :external_message,
      channel: :external,
      role: :user,
      content_ref: "sha256:input",
      parent_id: nil,
      causation_id: nil,
      visibility: :agent,
      context_generation: 0,
      context_candidate: true,
      occurred_at: "2026-08-26T00:00:00.000000Z",
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
      error_ref: nil,
      usage_ref: nil,
      started_at: "2026-08-26T00:00:00.000000Z",
      completed_at: "2026-08-26T00:00:01.000000Z",
      metadata: {"model" => "test"}
    )
  end

  let(:approval_request) do
    {
      "id" => "approval-1",
      "execution_id" => "execution-1",
      "items" => [
        {
          "tool_invocation_id" => "tool-invocation-1",
          "tool_call_id" => "provider-tool-call-1",
          "tool_name" => "protected_tool",
          "arguments" => {"value" => 1},
          "facts" => {},
          "reason" => "approval required",
          "origin" => "local",
          "metadata" => {}
        }
      ],
      "created_at" => "2026-08-26T00:00:01Z"
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
      created_at: "2026-08-26T00:00:00.000000Z",
      updated_at: "2026-08-26T00:00:02.000000Z",
      terminal_reason: nil,
      metadata: {"fixture" => "codec-test"}
    )
  end

  it "uses independent pre-1.0 0.x format versions per durable record type" do
    expect(described_class::AGENT_ROOT_FORMAT_VERSION).to eq("0.1")
    expect(described_class::AGENT_EXECUTION_FORMAT_VERSION).to eq("0.1")
    expect(described_class::JOURNAL_FORMAT_VERSION).to eq("0.1")
    expect(described_class::WORKFLOW_STATE_FORMAT_VERSION).to eq("0.1")
  end

  it "locks each 0.1 schema so a shape change requires an explicit version bump" do
    expect(described_class::AGENT_ROOT_KEYS).to eq(%w[
      agent_id agent_definition_id agent_definition_version agent_revision
      context_revision journal_position lifecycle_status transcript_generation
      created_at updated_at metadata
    ])
    expect(described_class::AGENT_EXECUTION_KEYS).to eq(%w[
      execution_id agent_id execution_revision status phase
      base_agent_revision base_context_revision base_journal_position
      working_records llm_calls approval_request result_ref error_ref
      created_at updated_at terminal_reason metadata
    ])
    expect(described_class::JOURNAL_RECORD_KEYS).to eq(%w[
      record_id agent_id sequence execution_id llm_call_id kind channel role
      content_ref parent_id causation_id visibility context_generation
      context_candidate occurred_at metadata
    ])
    expect(described_class::WORKFLOW_STATE_KEYS).to eq(%w[
      workflow_instance_id workflow_revision snapshot
    ])
  end

  it "encodes and decodes AgentRoot through DurableRecord" do
    record = described_class.encode_agent_root(root)

    expect(record).to be_a(Phronomy::Persistence::DurableRecord)
    expect(record.record_type).to eq("phronomy.agent_root")
    expect(record.format_version).to eq("0.1")
    expect(record.payload.fetch("lifecycle_status")).to eq("idle")
    expect(described_class.decode_agent_root(record).to_h).to eq(root.to_h)
  end

  it "encodes embedded JournalRecord and LLMCallRecord under AgentExecution format" do
    record = described_class.encode_agent_execution(execution)
    restored = described_class.decode_agent_execution(record)

    expect(record.record_type).to eq("phronomy.agent_execution")
    expect(record.payload.fetch("working_records").first)
      .not_to have_key("format_version")
    expect(record.payload.fetch("llm_calls").first)
      .not_to have_key("format_version")
    expect(record.payload.fetch("working_records").first.fetch("kind"))
      .to eq("external_message")
    expect(record.payload.fetch("llm_calls").first.fetch("status"))
      .to eq("completed")
    expect(restored.to_h).to eq(execution.to_h)
  end

  it "rejects an older format version instead of backward-decoding" do
    current = described_class.encode_agent_root(root)
    old = Phronomy::Persistence::DurableRecord.new(
      record_type: current.record_type,
      format_version: "0.0",
      payload: current.payload
    )

    expect do
      described_class.decode_agent_root(old)
    end.to raise_error(Phronomy::Persistence::SerializationError, /unsupported.*format version/)
  end

  it "rejects a record type mismatch" do
    current = described_class.encode_agent_root(root)
    wrong = Phronomy::Persistence::DurableRecord.new(
      record_type: "phronomy.agent_execution",
      format_version: current.format_version,
      payload: current.payload
    )

    expect do
      described_class.decode_agent_root(wrong)
    end.to raise_error(Phronomy::Persistence::SerializationError, /record type mismatch/)
  end

  it "rejects missing and unknown fields within the current version" do
    current = described_class.encode_agent_root(root)
    missing_payload = current.payload.to_h.except("metadata")
    unknown_payload = current.payload.to_h.merge("unexpected" => true)

    missing = Phronomy::Persistence::DurableRecord.new(
      record_type: current.record_type,
      format_version: current.format_version,
      payload: missing_payload
    )
    unknown = Phronomy::Persistence::DurableRecord.new(
      record_type: current.record_type,
      format_version: current.format_version,
      payload: unknown_payload
    )

    expect { described_class.decode_agent_root(missing) }
      .to raise_error(Phronomy::Persistence::SerializationError, /missing=.*metadata/)
    expect { described_class.decode_agent_root(unknown) }
      .to raise_error(Phronomy::Persistence::SerializationError, /unknown=.*unexpected/)
  end

  it "rejects wrong scalar types within the current AgentRoot format" do
    current = described_class.encode_agent_root(root)
    malformed = Phronomy::Persistence::DurableRecord.new(
      record_type: current.record_type,
      format_version: current.format_version,
      payload: current.payload.to_h.merge("agent_id" => 42)
    )

    expect do
      described_class.decode_agent_root(malformed)
    end.to raise_error(Phronomy::Persistence::SerializationError, /agent_id.*String/)
  end

  it "rejects wrong nested types within the current AgentExecution format" do
    current = described_class.encode_agent_execution(execution)
    payload = Marshal.load(Marshal.dump(current.payload))
    payload.fetch("working_records").first["context_candidate"] = "true"
    malformed = Phronomy::Persistence::DurableRecord.new(
      record_type: current.record_type,
      format_version: current.format_version,
      payload: payload
    )

    expect do
      described_class.decode_agent_execution(malformed)
    end.to raise_error(
      Phronomy::Persistence::SerializationError,
      /working_records\[0\].*context_candidate.*true or false/
    )
  end

  it "rejects unknown nested fields in the current AgentExecution schema" do
    current = described_class.encode_agent_execution(execution)
    payload = Marshal.load(Marshal.dump(current.payload))
    payload.fetch("llm_calls").first["unexpected"] = true
    malformed = Phronomy::Persistence::DurableRecord.new(
      record_type: current.record_type,
      format_version: current.format_version,
      payload: payload
    )

    expect do
      described_class.decode_agent_execution(malformed)
    end.to raise_error(Phronomy::Persistence::SerializationError, /llm_calls\[0\].*unknown/)
  end

  it "keeps application metadata extensible without relaxing the record schema" do
    enriched = root.with(
      agent_revision: root.agent_revision + 1,
      metadata: {"application" => {"arbitrary" => [1, 2, 3]}}
    )
    record = described_class.encode_agent_root(enriched)

    expect(record.payload.fetch("metadata").fetch("application"))
      .to eq("arbitrary" => [1, 2, 3])
  end

  it "encodes Workflow identity and revision in the semantic payload" do
    record = described_class.encode_workflow_state(
      workflow_instance_id: "workflow-1",
      workflow_revision: 2,
      snapshot: {fields: {count: 2}, phase: "pause"}
    )
    decoded = described_class.decode_workflow_state(
      record,
      expected_workflow_instance_id: "workflow-1"
    )

    expect(record.record_type).to eq("phronomy.workflow_state")
    expect(record.payload.fetch("workflow_revision")).to eq(2)
    expect(decoded).to eq(
      snapshot: {"fields" => {"count" => 2}, "phase" => "pause"},
      revision: 2
    )
  end

  it "keeps Workflow Symbol normalization explicit and isolated to Workflow fields" do
    record = described_class.encode_workflow_state(
      workflow_instance_id: "workflow-symbols",
      workflow_revision: 1,
      snapshot: {
        fields: {status: :ready, nested: {mode: :fast}},
        phase: :pause
      }
    )

    expect(record.payload.fetch("snapshot")).to eq(
      "fields" => {
        "status" => "ready",
        "nested" => {"mode" => "fast"}
      },
      "phase" => "pause"
    )
  end
end
