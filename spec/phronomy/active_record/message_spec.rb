# frozen_string_literal: true

require "spec_helper"
require_relative "../../support/active_record_setup"

RSpec.describe Phronomy::ActiveRecord::Message do
  before { PhronomyMessageRecord.delete_all }

  describe "validations" do
    it "is valid with thread_id, role, and content" do
      record = PhronomyMessageRecord.new(thread_id: "t1", role: "user", content: "Hello")
      expect(record.valid?).to be true
    end

    it "is invalid without thread_id" do
      record = PhronomyMessageRecord.new(role: "user", content: "Hello")
      expect(record.valid?).to be false
      expect(record.errors[:thread_id]).to be_present
    end

    it "is invalid without role" do
      record = PhronomyMessageRecord.new(thread_id: "t1", content: "Hello")
      expect(record.valid?).to be false
      expect(record.errors[:role]).to be_present
    end

    it "is valid with nil content (tool call messages)" do
      record = PhronomyMessageRecord.new(thread_id: "t1", role: "assistant", content: nil)
      expect(record.valid?).to be true
    end

    it "is valid with empty string content" do
      record = PhronomyMessageRecord.new(thread_id: "t1", role: "assistant", content: "")
      expect(record.valid?).to be true
    end

    it "persists valid records to the database" do
      PhronomyMessageRecord.create!(thread_id: "t1", role: "user", content: "hi")
      expect(PhronomyMessageRecord.find_by(thread_id: "t1")).not_to be_nil
    end

    it "allows tool_calls_json to be nil" do
      record = PhronomyMessageRecord.new(thread_id: "t1", role: "user", content: "hi", tool_calls_json: nil)
      expect(record.valid?).to be true
    end
  end

  describe "module inclusion" do
    it "is included in PhronomyMessageRecord" do
      expect(PhronomyMessageRecord.ancestors).to include(Phronomy::ActiveRecord::Message)
    end
  end
end
