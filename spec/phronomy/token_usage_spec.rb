# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::LLMAdapter::TokenUsage do
  describe ".zero" do
    it "returns a LLMAdapter::TokenUsage with all-zero counts" do
      z = described_class.zero
      expect(z.input).to eq(0)
      expect(z.output).to eq(0)
      expect(z.cached).to eq(0)
      expect(z.cache_creation).to eq(0)
    end
  end

  describe "unknown and invalid usage" do
    it "preserves unknown counts instead of reporting zero" do
      expect(described_class.new.to_h.values).to all(be_nil)
    end

    it "rejects negative or non-integer counts" do
      [-1, 1.5, "3"].each do |value|
        expect { described_class.new(input: value) }.to raise_error(ArgumentError)
      end
    end

    it "is immutable" do
      expect(described_class.new(input: 1)).to be_frozen
    end
  end

  describe "#+" do
    it "adds all fields of two LLMAdapter::TokenUsage objects" do
      a = described_class.new(input: 10, output: 5, cached: 2, cache_creation: 1)
      b = described_class.new(input: 20, output: 8, cached: 3, cache_creation: 0)
      sum = a + b
      expect(sum.input).to eq(30)
      expect(sum.output).to eq(13)
      expect(sum.cached).to eq(5)
      expect(sum.cache_creation).to eq(1)
    end

    it "treats nil as zero on the right side" do
      a = described_class.new(input: 10, output: 5, cached: 0, cache_creation: 0)
      sum = a + nil
      expect(sum.input).to eq(10)
      expect(sum.output).to eq(5)
    end

    it "is associative with .zero" do
      a = described_class.new(input: 7, output: 3, cached: 1, cache_creation: 0)
      expect(described_class.zero + a).to eq(a)
      expect(a + described_class.zero).to eq(a)
    end
  end

  describe "#to_h" do
    it "returns a Hash with all four keys" do
      usage = described_class.new(input: 1, output: 2, cached: 3, cache_creation: 4)
      expect(usage.to_h).to eq({input: 1, output: 2, cached: 3, cache_creation: 4})
    end
  end

  describe "#==" do
    it "is equal when all fields match" do
      expect(described_class.new(input: 1, output: 2, cached: 3, cache_creation: 4)).to eq(
        described_class.new(input: 1, output: 2, cached: 3, cache_creation: 4)
      )
    end

    it "is not equal when any field differs" do
      expect(described_class.new(input: 1, output: 2, cached: 3, cache_creation: 4)).not_to eq(
        described_class.new(input: 1, output: 2, cached: 3, cache_creation: 5)
      )
    end
  end

  describe "#+ with nil fields" do
    it "returns nil for each field when both operands have nil for that field" do
      a = described_class.new(input: nil, output: nil, cached: nil, cache_creation: nil)
      b = described_class.new(input: nil, output: nil, cached: nil, cache_creation: nil)
      result = a + b
      expect(result.input).to be_nil
      expect(result.output).to be_nil
    end
  end
end
