# frozen_string_literal: true

require "spec_helper"
require_relative "../../support/active_record_setup"

RSpec.describe Phronomy::ActiveRecord::Checkpoint do
  before { PhronomyCheckpointRecord.delete_all }

  describe "validations" do
    it "is valid with thread_id and state_json" do
      record = PhronomyCheckpointRecord.new(thread_id: "t1", state_json: "{}")
      expect(record.valid?).to be true
    end

    it "is invalid without thread_id" do
      record = PhronomyCheckpointRecord.new(state_json: "{}")
      expect(record.valid?).to be false
      expect(record.errors[:thread_id]).to be_present
    end

    it "is invalid without state_json" do
      record = PhronomyCheckpointRecord.new(thread_id: "t1")
      expect(record.valid?).to be false
      expect(record.errors[:state_json]).to be_present
    end

    it "allows interrupted_at to be nil" do
      record = PhronomyCheckpointRecord.new(thread_id: "t1", state_json: "{}", interrupted_at: nil)
      expect(record.valid?).to be true
    end

    it "allows completed_node to be nil" do
      record = PhronomyCheckpointRecord.new(thread_id: "t1", state_json: "{}", completed_node: nil)
      expect(record.valid?).to be true
    end

    it "persists valid records to the database" do
      PhronomyCheckpointRecord.create!(thread_id: "t1", state_json: '{"score":1}')
      expect(PhronomyCheckpointRecord.find_by(thread_id: "t1")).not_to be_nil
    end
  end

  describe "module inclusion" do
    it "is included in PhronomyCheckpointRecord" do
      expect(PhronomyCheckpointRecord.ancestors).to include(Phronomy::ActiveRecord::Checkpoint)
    end
  end
end
