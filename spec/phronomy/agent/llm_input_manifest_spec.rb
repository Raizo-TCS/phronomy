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

  it "raises on invalid call_mode" do
    expect do
      described_class.new(
        call_sequence: 1,
        call_mode: :invalid_mode,
        segments: [],
        model_config_ref: "sha256:m"
      )
    end.to raise_error(ArgumentError, /invalid manifest call mode/)
  end

  it "raises when call_sequence is not positive" do
    expect do
      described_class.new(
        call_sequence: 0,
        call_mode: :complete,
        segments: [],
        model_config_ref: "sha256:m"
      )
    end.to raise_error(ArgumentError, /call_sequence must be positive/)
  end

  it "raises when segment positions are not contiguous" do
    s0 = segment_class.new(position: 0, category: :current_input, role: :user,
      content_ref: "sha256:x", delivery: :ask_argument,
      tool_call_id: nil, metadata: {})
    s2 = segment_class.new(position: 2, category: :current_input, role: :user,
      content_ref: "sha256:y", delivery: :ask_argument,
      tool_call_id: nil, metadata: {})
    expect do
      described_class.new(
        call_sequence: 1,
        call_mode: :ask,
        segments: [s0, s2],
        model_config_ref: "sha256:m"
      )
    end.to raise_error(ArgumentError, /manifest positions must be contiguous/)
  end

  it "raises when ask_argument count does not match call_mode expectation" do
    ask_segment = segment_class.new(
      position: 0, category: :current_input, role: :user,
      content_ref: "sha256:x", delivery: :ask_argument,
      tool_call_id: nil, metadata: {}
    )
    expect do
      described_class.new(
        call_sequence: 2,
        call_mode: :complete,
        segments: [ask_segment],
        model_config_ref: "sha256:m"
      )
    end.to raise_error(ArgumentError, /complete manifest requires 0 ask_argument/)
  end

  it "accepts optional metadata fields and serializes segments with nil role" do
    segment = segment_class.new(
      position: 0, category: :instruction, role: nil,
      content_ref: "sha256:inst", delivery: :inline,
      tool_call_id: nil, metadata: {}
    )
    manifest = described_class.new(
      call_sequence: 1,
      call_mode: :complete,
      segments: [segment],
      model_config_ref: "sha256:m",
      tool_definitions_ref: "sha256:tools",
      ruby_llm_version: "1.0.0",
      adapter_name: "openai",
      adapter_version: "1"
    )
    expect(manifest.tool_definitions_ref).to eq("sha256:tools")
    seg_h = segment.to_h
    expect(seg_h["role"]).to be_nil
  end
end
