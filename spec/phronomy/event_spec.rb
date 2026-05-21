# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Event do
  describe ".new / Data.define interface" do
    subject(:event) { described_class.new(type: :start, target_id: "abc-123", payload: nil) }

    it "exposes type" do
      expect(event.type).to eq(:start)
    end

    it "exposes target_id" do
      expect(event.target_id).to eq("abc-123")
    end

    it "exposes payload" do
      expect(event.payload).to be_nil
    end

    it "is frozen (immutable)" do
      expect(event).to be_frozen
    end
  end

  describe "equality" do
    it "is equal to another Event with the same attributes" do
      e1 = described_class.new(type: :finished, target_id: "t1", payload: "ctx")
      e2 = described_class.new(type: :finished, target_id: "t1", payload: "ctx")
      expect(e1).to eq(e2)
    end

    it "is not equal when any attribute differs" do
      base = described_class.new(type: :finished, target_id: "t1", payload: nil)
      expect(base).not_to eq(described_class.new(type: :halted, target_id: "t1", payload: nil))
      expect(base).not_to eq(described_class.new(type: :finished, target_id: "t2", payload: nil))
    end
  end
end
