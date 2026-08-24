# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::ToolDefinitionSet do
  describe ".normalize" do
    subject(:normalize) { described_class.method(:normalize) }

    it "converts Array elements recursively" do
      result = described_class.normalize([:a, "b", 1])
      expect(result).to eq(["a", "b", 1])
    end

    it "converts Symbol to String" do
      expect(described_class.normalize(:my_key)).to eq("my_key")
    end

    it "passes through String values unchanged" do
      expect(described_class.normalize("hello")).to eq("hello")
    end

    it "passes through Integer values unchanged" do
      expect(described_class.normalize(42)).to eq(42)
    end

    it "passes through nil unchanged" do
      expect(described_class.normalize(nil)).to be_nil
    end
  end
end
