# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::RecoveryRules do
  it "preserves missing-material validation precedence and exact messages" do
    expect {
      described_class.validate_resolution_material!(
        outcome: :succeeded, result_present: false, error_present: true
      )
    }.to raise_error(ArgumentError, "Recovery :succeeded requires result:")
    expect {
      described_class.validate_resolution_material!(
        outcome: :failed, result_present: true, error_present: false
      )
    }.to raise_error(ArgumentError, "Recovery :failed requires error:")
  end

  it "retains frozen subject identity and rejects empty or missing operation IDs" do
    subject = described_class.normalize_subject("type" => "tool_invocation", "tool_invocation_id" => 42)
    expect(subject).to eq(type: :tool_invocation, tool_invocation_id: "42")
    expect(subject).to be_frozen
    expect(subject.fetch(:tool_invocation_id)).to be_frozen
    expect {
      described_class.normalize_subject(type: :llm_call, llm_call_id: "")
    }.to raise_error(ArgumentError, "llm_call_id must not be empty")
    expect { described_class.normalize_subject(type: :llm_call) }.to raise_error(KeyError)
  end

  describe ".normalize_outcome" do
    it "returns the normalized symbol for valid outcomes" do
      expect(described_class.normalize_outcome(:succeeded)).to eq(:succeeded)
      expect(described_class.normalize_outcome(:failed)).to eq(:failed)
      expect(described_class.normalize_outcome(:not_performed)).to eq(:not_performed)
    end

    it "raises ArgumentError for an unsupported outcome" do
      expect {
        described_class.normalize_outcome(:unknown_outcome)
      }.to raise_error(ArgumentError, /unsupported Recovery outcome/)
    end

    it "accepts string-form outcomes via to_sym" do
      expect(described_class.normalize_outcome("succeeded")).to eq(:succeeded)
    end
  end

  describe ".validate_resolution_material!" do
    it "accepts :succeeded with result and no error" do
      expect(
        described_class.validate_resolution_material!(
          outcome: :succeeded, result_present: true, error_present: false
        )
      ).to be true
    end

    it "raises when :succeeded is resolved with error: present" do
      expect {
        described_class.validate_resolution_material!(
          outcome: :succeeded, result_present: true, error_present: true
        )
      }.to raise_error(ArgumentError, /forbids error/)
    end

    it "accepts :failed with error and no result" do
      expect(
        described_class.validate_resolution_material!(
          outcome: :failed, result_present: false, error_present: true
        )
      ).to be true
    end

    it "raises when :failed is resolved without error" do
      expect {
        described_class.validate_resolution_material!(
          outcome: :failed, result_present: false, error_present: false
        )
      }.to raise_error(ArgumentError, /requires error/)
    end

    it "raises when :failed is resolved with result: present" do
      expect {
        described_class.validate_resolution_material!(
          outcome: :failed, result_present: true, error_present: true
        )
      }.to raise_error(ArgumentError, /forbids result/)
    end

    it "accepts :not_performed with neither result nor error" do
      expect(
        described_class.validate_resolution_material!(
          outcome: :not_performed, result_present: false, error_present: false
        )
      ).to be true
    end

    it "raises when :not_performed is resolved with error: present" do
      expect {
        described_class.validate_resolution_material!(
          outcome: :not_performed, result_present: false, error_present: true
        )
      }.to raise_error(ArgumentError, /neither result: nor error:/)
    end
  end

  describe ".normalize_subject" do
    it "normalizes a :persistence_operation subject" do
      result = described_class.normalize_subject(
        type: :persistence_operation,
        entity: :agent
      )
      expect(result).to eq(type: :persistence_operation, entity: :agent)
    end

    it "raises for an unsupported subject type" do
      expect {
        described_class.normalize_subject(type: :unknown_subject_type, id: "x")
      }.to raise_error(ArgumentError, /unsupported Recovery subject type/)
    end
  end

  describe ".subject_key" do
    it "builds a persistence_operation key" do
      key = described_class.subject_key(type: :persistence_operation, entity: :workflow)
      expect(key).to eq("persistence_operation:workflow")
    end

    it "builds an llm_call key" do
      key = described_class.subject_key(type: :llm_call, llm_call_id: "call-42")
      expect(key).to eq("llm_call:call-42")
    end

    it "builds a tool_invocation key" do
      key = described_class.subject_key(type: :tool_invocation, tool_invocation_id: "inv-1")
      expect(key).to eq("tool_invocation:inv-1")
    end
  end

  describe ".subject_equal?" do
    it "returns true when subjects are logically equal" do
      expect(
        described_class.subject_equal?(
          {type: :llm_call, llm_call_id: "c1"},
          {type: :llm_call, llm_call_id: "c1"}
        )
      ).to be true
    end

    it "returns false when subjects differ" do
      expect(
        described_class.subject_equal?(
          {type: :llm_call, llm_call_id: "c1"},
          {type: :llm_call, llm_call_id: "c2"}
        )
      ).to be false
    end

    it "returns false and does not raise when a subject is invalid" do
      expect(
        described_class.subject_equal?(
          {type: :bad_type},
          {type: :llm_call, llm_call_id: "c1"}
        )
      ).to be false
    end
  end

  describe "Classification" do
    it "raises ArgumentError for an unknown disposition" do
      expect {
        Phronomy::Agent::RecoveryRules::Classification.new(
          disposition: :bogus_disposition,
          reason: :test
        )
      }.to raise_error(ArgumentError, /unknown Recovery disposition/)
    end

    it "normalises string-form disposition" do
      c = Phronomy::Agent::RecoveryRules::Classification.new(
        disposition: "resumable",
        reason: :pending_llm
      )
      expect(c.disposition).to eq(:resumable)
    end
  end
end
