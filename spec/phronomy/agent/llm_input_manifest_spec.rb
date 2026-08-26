# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::LLMInputManifest do
  let(:segment_class) { Phronomy::Agent::LLMInputManifest::Segment }

  it "rejects an unknown delivery in the Segment constructor" do
    expect {
      segment_class.new(
        position: 0, category: :instruction, role: nil,
        content_ref: "sha256:x", delivery: :inline,
        tool_call_id: nil, metadata: {}
      )
    }.to raise_error(ArgumentError, /unknown Segment delivery.*:inline/)
  end

  it "rejects an unknown delivery in the Segment durable decoder" do
    segment = segment_class.new(
      position: 0, category: :instruction, role: nil,
      content_ref: "sha256:x", delivery: :chat_message,
      tool_call_id: nil, metadata: {}
    )
    bad_hash = segment.to_h.merge("delivery" => "inline")

    expect {
      segment_class.from_h(bad_hash)
    }.to raise_error(Phronomy::Persistence::SerializationError, /delivery must be one of/)
  end

  it "uses the pre-1.0 durable codec version convention" do
    expect(described_class::VERSION).to eq("0.1")
  end

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
    expect(manifest.to_h.fetch("version")).to eq("0.1")
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
      content_ref: "sha256:inst", delivery: :chat_message,
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

  it "round-trips the current manifest schema" do
    manifest = described_class.new(
      call_sequence: 1,
      call_mode: :complete,
      segments: [],
      model_config_ref: "sha256:m"
    )

    expect(described_class.from_h(manifest.to_h).to_h).to eq(manifest.to_h)
  end

  it "rejects the old integer version in normal load" do
    manifest = described_class.new(
      call_sequence: 1,
      call_mode: :complete,
      segments: [],
      model_config_ref: "sha256:m"
    ).to_h
    manifest["version"] = 1

    expect do
      described_class.from_h(manifest)
    end.to raise_error(Phronomy::Persistence::SerializationError, /unsupported.*version/)
  end

  it "rejects missing and unknown current-schema fields" do
    current = described_class.new(
      call_sequence: 1,
      call_mode: :complete,
      segments: [],
      model_config_ref: "sha256:m"
    ).to_h

    missing = current.dup.tap { |hash| hash.delete("version") }
    unknown = current.merge("future_field" => true)

    expect { described_class.from_h(missing) }
      .to raise_error(Phronomy::Persistence::SerializationError, /missing=.*version/)
    expect { described_class.from_h(unknown) }
      .to raise_error(Phronomy::Persistence::SerializationError, /unknown=.*future_field/)
  end

  it "requires String keys in the current durable decoder" do
    current = described_class.new(
      call_sequence: 1,
      call_mode: :complete,
      segments: [],
      model_config_ref: "sha256:m"
    ).to_h
    symbolized = current.transform_keys(&:to_sym)

    expect do
      described_class.from_h(symbolized)
    end.to raise_error(
      Phronomy::Persistence::SerializationError,
      /keys must all be String/
    )
  end

  it "does not coerce scalar durable field types" do
    current = described_class.new(
      call_sequence: 1,
      call_mode: :complete,
      segments: [],
      model_config_ref: "sha256:m"
    ).to_h

    wrong_sequence = current.merge("call_sequence" => "1")
    wrong_ref = current.merge("model_config_ref" => 123)

    expect do
      described_class.from_h(wrong_sequence)
    end.to raise_error(
      Phronomy::Persistence::SerializationError,
      /call_sequence must be a positive Integer/
    )
    expect do
      described_class.from_h(wrong_ref)
    end.to raise_error(
      Phronomy::Persistence::SerializationError,
      /model_config_ref must be a non-empty String/
    )
  end

  it "does not coerce Segment durable field types" do
    current = described_class.new(
      call_sequence: 1,
      call_mode: :complete,
      segments: [
        segment_class.new(
          position: 0,
          category: :instruction,
          role: nil,
          content_ref: "sha256:inst",
          delivery: :chat_message,
          tool_call_id: nil,
          metadata: {}
        )
      ],
      model_config_ref: "sha256:m"
    ).to_h

    wrong_position = Marshal.load(Marshal.dump(current))
    wrong_position.fetch("segments").first["position"] = "0"

    wrong_content_ref = Marshal.load(Marshal.dump(current))
    wrong_content_ref.fetch("segments").first["content_ref"] = 123

    expect do
      described_class.from_h(wrong_position)
    end.to raise_error(
      Phronomy::Persistence::SerializationError,
      /segment position must be a non-negative Integer/
    )
    expect do
      described_class.from_h(wrong_content_ref)
    end.to raise_error(
      Phronomy::Persistence::SerializationError,
      /segment content_ref must be a non-empty String/
    )
  end
end
