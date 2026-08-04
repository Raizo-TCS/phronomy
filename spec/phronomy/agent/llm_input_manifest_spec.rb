# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::LLMInputManifest do
  let(:segment_class) { Phronomy::Agent::LLMInputManifest::Segment }

  it "requires one ask argument for the first call" do
    segment = segment_class.new(
      position: 0,
      category: :current_input,
      role: :user,
      content_ref: "sha256:x",
      delivery: :ask_argument,
      tool_call_id: nil,
      metadata: {}
    )
    manifest = described_class.new(
      call_sequence: 1,
      call_mode: :ask,
      segments: [segment],
      model_config_ref: "sha256:m"
    )
    expect(manifest.call_sequence).to eq(1)
  end

  it "requires zero ask arguments for follow-up complete calls" do
    expect do
      described_class.new(
        call_sequence: 2,
        call_mode: :complete,
        segments: [],
        model_config_ref: "sha256:m"
      )
    end.not_to raise_error
  end
end
