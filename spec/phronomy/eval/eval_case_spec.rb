# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Eval::EvalCase do
  describe ".new" do
    it "stores input and expected" do
      ec = described_class.new(input: "hello", expected: "world")
      expect(ec.input).to eq("hello")
      expect(ec.expected).to eq("world")
    end

    it "defaults metadata to empty hash" do
      ec = described_class.new(input: "a", expected: "b")
      expect(ec.metadata).to eq({})
    end

    it "stores custom metadata" do
      ec = described_class.new(input: "a", expected: "b", metadata: {difficulty: :hard})
      expect(ec.metadata[:difficulty]).to eq(:hard)
    end
  end

  describe "value semantics" do
    it "is equal to another EvalCase with same attributes" do
      a = described_class.new(input: "x", expected: "y")
      b = described_class.new(input: "x", expected: "y")
      expect(a).to eq(b)
    end

    it "is frozen" do
      ec = described_class.new(input: "a", expected: "b")
      expect(ec).to be_frozen
    end
  end
end
