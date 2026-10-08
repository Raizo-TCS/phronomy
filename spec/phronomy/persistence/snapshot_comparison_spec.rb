# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Persistence::SnapshotComparison do
  describe "existing evidence semantics" do
    it "keeps the pre revision decisive even when its snapshot differs" do
      [{value: 1}, {value: 2}].each do |snapshot|
        expect(described_class.compare_revisioned_snapshot(
          record: {revision: 3, snapshot: snapshot}, expected_pre_revision: 3,
          intended_snapshot: {value: 2}
        )).to eq(:pre_state)
      end
    end

    it "recognizes normalized nested post state without changing the evidence" do
      snapshot = {"items" => [{"state" => "done"}]}.freeze
      intended = {items: [{state: :done}]}.freeze
      expect(described_class.compare_revisioned_snapshot(
        record: {"revision" => 4, "snapshot" => snapshot},
        expected_pre_revision: 3, intended_snapshot: intended
      )).to eq(:post_state)
      expect(snapshot).to eq("items" => [{"state" => "done"}])
      expect(intended).to eq(items: [{state: :done}])
    end

    it "requires the explicit post revision even when the intended snapshot matches" do
      expect(described_class.compare_revisioned_snapshot(
        record: {revision: 4, snapshot: {value: 2}}, expected_pre_revision: 3,
        intended_snapshot: {value: 2}, intended_post_revision: 5
      )).to eq(:conflict)
    end

    it "preserves post comparison priority when the supplied revisions coincide" do
      expect(described_class.compare_revisions(
        current_revision: 3, expected_pre_revision: 3, intended_post_revision: 3
      )).to eq(:post_state)
      expect(described_class.compare_revisioned_snapshot(
        record: {revision: 3, snapshot: {}}, expected_pre_revision: 3,
        intended_snapshot: {}, intended_post_revision: 3
      )).to eq(:post_state)
    end

    it "recognizes an absent initial record before considering the post revision" do
      expect(described_class.compare_revisioned_snapshot(
        record: nil, expected_pre_revision: nil, intended_snapshot: {},
        intended_post_revision: 4
      )).to eq(:pre_state)
    end

    it "prefers record accessors, then symbol keys, then string keys" do
      record = {:revision => 3, "revision" => 4}
      expect(described_class.fetch_value(record, :revision)).to eq(3)
      def record.revision = 5
      expect(described_class.fetch_value(record, :revision)).to eq(5)
    end

    it "leaves read errors to the calling domain rather than classifying them" do
      failure = IOError.new("readback failed")
      record = Object.new
      record.define_singleton_method(:revision) { raise failure }
      expect {
        described_class.compare_revisioned_snapshot(
          record: record, expected_pre_revision: 3, intended_snapshot: {}
        )
      }.to raise_error { |error| expect(error).to equal(failure) }
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

  it "reconciles revisioned Workflow snapshots as post, pre, or conflict" do
    intended = {fields: {count: 2}, phase: "done"}

    expect(
      described_class.compare_revisioned_snapshot(
        record: {revision: 4, snapshot: intended},
        expected_pre_revision: 3,
        intended_snapshot: intended
      )
    ).to eq(:post_state)

    expect(
      described_class.compare_revisioned_snapshot(
        record: {revision: 3, snapshot: {fields: {count: 1}}},
        expected_pre_revision: 3,
        intended_snapshot: intended
      )
    ).to eq(:pre_state)

    expect(
      described_class.compare_revisioned_snapshot(
        record: {revision: 4, snapshot: {fields: {count: 99}}},
        expected_pre_revision: 3,
        intended_snapshot: intended
      )
    ).to eq(:conflict)
  end
end
