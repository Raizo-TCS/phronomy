# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Eval::Dataset do
  let(:pairs) do
    [
      {input: "What is 2+2?", expected: "4"},
      {input: "Capital of France?", expected: "Paris"}
    ]
  end

  describe ".from_array" do
    it "creates a Dataset from an array of hashes" do
      ds = described_class.from_array(pairs)
      expect(ds.size).to eq(2)
    end

    it "converts hashes to EvalCase objects" do
      ds = described_class.from_array(pairs)
      expect(ds.first).to be_a(Phronomy::Eval::EvalCase)
      expect(ds.first.input).to eq("What is 2+2?")
      expect(ds.first.expected).to eq("4")
    end

    it "forwards metadata when present" do
      data = [{input: "q", expected: "a", metadata: {tag: :easy}}]
      ds = described_class.from_array(data)
      expect(ds.first.metadata[:tag]).to eq(:easy)
    end
  end

  describe "#size" do
    it "returns the number of cases" do
      expect(described_class.from_array(pairs).size).to eq(2)
    end

    it "returns 0 for an empty dataset" do
      expect(described_class.new.size).to eq(0)
    end
  end

  describe "#each / Enumerable" do
    it "iterates over each EvalCase" do
      ds = described_class.from_array(pairs)
      inputs = ds.map(&:input)
      expect(inputs).to eq(["What is 2+2?", "Capital of France?"])
    end

    it "supports #to_a" do
      ds = described_class.from_array(pairs)
      expect(ds.to_a.size).to eq(2)
    end
  end
end
