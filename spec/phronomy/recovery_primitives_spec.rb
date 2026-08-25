# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Recovery do
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

  describe ".compare_revisions" do
    it "returns :post_state when current equals intended" do
      expect(
        described_class.compare_revisions(
          current_revision: 3,
          expected_pre_revision: 2,
          intended_post_revision: 3
        )
      ).to eq(:post_state)
    end

    it "returns :pre_state when current equals expected pre" do
      expect(
        described_class.compare_revisions(
          current_revision: 2,
          expected_pre_revision: 2,
          intended_post_revision: 3
        )
      ).to eq(:pre_state)
    end

    it "returns :conflict when current matches neither" do
      expect(
        described_class.compare_revisions(
          current_revision: 99,
          expected_pre_revision: 2,
          intended_post_revision: 3
        )
      ).to eq(:conflict)
    end
  end

  describe ".compare_revisioned_snapshot" do
    let(:intended) { {fields: {v: 2}, phase: "done"} }

    it "returns :pre_state when both record and expected_pre_revision are nil" do
      expect(
        described_class.compare_revisioned_snapshot(
          record: nil,
          expected_pre_revision: nil,
          intended_snapshot: intended
        )
      ).to eq(:pre_state)
    end

    it "returns :conflict when record is nil but expected_pre_revision is set" do
      expect(
        described_class.compare_revisioned_snapshot(
          record: nil,
          expected_pre_revision: 3,
          intended_snapshot: intended
        )
      ).to eq(:conflict)
    end

    it "matches :post_state using intended_post_revision when provided" do
      expect(
        described_class.compare_revisioned_snapshot(
          record: {revision: 5, snapshot: intended},
          expected_pre_revision: 3,
          intended_snapshot: intended,
          intended_post_revision: 5
        )
      ).to eq(:post_state)
    end

    it "does not match :post_state when revision matches but snapshot differs" do
      expect(
        described_class.compare_revisioned_snapshot(
          record: {revision: 5, snapshot: {fields: {v: 99}, phase: "done"}},
          expected_pre_revision: 3,
          intended_snapshot: intended,
          intended_post_revision: 5
        )
      ).to eq(:conflict)
    end
  end

  describe ".normalize_value" do
    it "recursively normalises an Array" do
      expect(
        described_class.normalize_value([:a, {b: :c}])
      ).to eq(["a", {"b" => "c"}])
    end

    it "converts a Symbol to a String" do
      expect(described_class.normalize_value(:my_sym)).to eq("my_sym")
    end

    it "returns scalar values unchanged" do
      expect(described_class.normalize_value(42)).to eq(42)
      expect(described_class.normalize_value(nil)).to be_nil
      expect(described_class.normalize_value("str")).to eq("str")
    end
  end

  describe ".fetch_value" do
    it "returns nil when record is nil" do
      expect(described_class.fetch_value(nil, :key)).to be_nil
    end

    it "uses public_send when record responds to the key method" do
      record = Struct.new(:revision).new(7)
      expect(described_class.fetch_value(record, :revision)).to eq(7)
    end

    it "uses [] when record responds to key? for symbol key" do
      record = {revision: 4}
      expect(described_class.fetch_value(record, :revision)).to eq(4)
    end

    it "falls back to string key lookup" do
      record = {"revision" => 9}
      expect(described_class.fetch_value(record, :revision)).to eq(9)
    end

    it "returns nil when key is absent" do
      expect(described_class.fetch_value({other: 1}, :missing)).to be_nil
    end
  end

  describe "Classification" do
    it "raises ArgumentError for an unknown disposition" do
      expect {
        Phronomy::Recovery::Classification.new(
          disposition: :bogus_disposition,
          reason: :test
        )
      }.to raise_error(ArgumentError, /unknown Recovery disposition/)
    end

    it "normalises string-form disposition" do
      c = Phronomy::Recovery::Classification.new(
        disposition: "resumable",
        reason: :pending_llm
      )
      expect(c.disposition).to eq(:resumable)
    end
  end
end
