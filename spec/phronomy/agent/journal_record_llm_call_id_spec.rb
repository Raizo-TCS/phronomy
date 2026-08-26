# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::JournalRecord do
  it "persists runtime Provider Call provenance as a top-level llm_call_id" do
    record = described_class.new(
      agent_id: "agent-1",
      execution_id: "execution-1",
      llm_call_id: "llm-1",
      kind: :assistant_message,
      channel: :llm,
      role: :assistant,
      content_ref: "sha256:content"
    )

    restored = described_class.from_h(record.to_h)
    expect(restored.llm_call_id).to eq("llm-1")
  end

  it "accepts nil llm_call_id in a current-format payload" do
    record = described_class.from_h(
      "record_id" => "record-1",
      "agent_id" => "agent-1",
      "sequence" => 1,
      "execution_id" => nil,
      "llm_call_id" => nil,
      "kind" => "external_message",
      "channel" => "external",
      "role" => "user",
      "content_ref" => "sha256:content",
      "parent_id" => nil,
      "causation_id" => nil,
      "visibility" => "agent",
      "context_generation" => 0,
      "context_candidate" => true,
      "occurred_at" => "2026-08-08T00:00:00Z",
      "metadata" => {}
    )

    expect(record.llm_call_id).to be_nil
  end
end
