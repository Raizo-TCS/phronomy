# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Workflow::Persistence::Codec do
  it "preserves the initial Workflow record version and schema" do
    expect(described_class::WORKFLOW_STATE_FORMAT_VERSION).to eq("0.1")
    expect(described_class::WORKFLOW_STATE_KEYS).to eq(%w[workflow_instance_id workflow_revision snapshot])
    expect(described_class::WORKFLOW_SNAPSHOT_KEYS).to eq(%w[fields phase])
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

  it "rejects a workflow state with wrong expected_workflow_instance_id" do
    record = described_class.encode_workflow_state(
      workflow_instance_id: "real-id",
      workflow_revision: 1,
      snapshot: {fields: {}, phase: nil}
    )
    expect {
      described_class.decode_workflow_state(record, expected_workflow_instance_id: "wrong-id")
    }.to raise_error(Phronomy::Storage::SerializationError, /mismatch/)
  end

  it "rejects a workflow snapshot with non-Hash fields" do
    record = described_class.encode_workflow_state(
      workflow_instance_id: "wf-1",
      workflow_revision: 1,
      snapshot: {fields: {}, phase: nil}
    )
    bad_payload = record.payload.merge(
      "snapshot" => record.payload.fetch("snapshot").merge("fields" => "not-a-hash")
    )
    bad_record = Phronomy::Storage::DurableRecord.new(
      record_type: Phronomy::Workflow::Persistence::Codec::WORKFLOW_STATE_RECORD_TYPE,
      format_version: Phronomy::Workflow::Persistence::Codec::WORKFLOW_STATE_FORMAT_VERSION,
      payload: bad_payload
    )
    expect {
      described_class.decode_workflow_state(bad_record)
    }.to raise_error(Phronomy::Storage::SerializationError, /fields must be a Hash/)
  end

  it "rejects a workflow snapshot with non-String phase" do
    record = described_class.encode_workflow_state(
      workflow_instance_id: "wf-1",
      workflow_revision: 1,
      snapshot: {fields: {}, phase: nil}
    )
    bad_payload = record.payload.merge(
      "snapshot" => record.payload.fetch("snapshot").merge("phase" => 42)
    )
    bad_record = Phronomy::Storage::DurableRecord.new(
      record_type: Phronomy::Workflow::Persistence::Codec::WORKFLOW_STATE_RECORD_TYPE,
      format_version: Phronomy::Workflow::Persistence::Codec::WORKFLOW_STATE_FORMAT_VERSION,
      payload: bad_payload
    )
    expect {
      described_class.decode_workflow_state(bad_record)
    }.to raise_error(Phronomy::Storage::SerializationError, /phase must be a String or nil/)
  end
end
