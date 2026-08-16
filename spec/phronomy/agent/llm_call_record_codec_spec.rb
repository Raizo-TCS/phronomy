# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe Phronomy::Agent::LLMCallRecord do
  let(:record) do
    described_class.new(
      llm_call_id: "call-1",
      execution_id: "execution-1",
      sequence: 1,
      status: :completed,
      manifest_ref: "sha256:manifest",
      output_ref: "sha256:output",
      usage_ref: "sha256:usage",
      completed_at: "2026-08-16T00:00:01.000000Z",
      metadata: {"model_id" => "test-model"}
    )
  end

  it "round-trips its canonical Hash representation" do
    restored = described_class.from_h(record.to_h)

    expect(restored.to_h).to eq(record.to_h)
  end

  it "round-trips after JSON serialization" do
    parsed = JSON.parse(JSON.generate(record.to_h))
    restored = described_class.from_h(parsed)

    expect(restored.to_h).to eq(record.to_h)
  end

  it "accepts Symbol top-level keys" do
    symbolized = record.to_h.transform_keys(&:to_sym)

    expect(described_class.from_h(symbolized).to_h).to eq(record.to_h)
  end
end
