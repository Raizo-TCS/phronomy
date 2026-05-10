# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Eval::EvalResult do
  let(:eval_case) { Phronomy::Eval::EvalCase.new(input: "q", expected: "a") }

  describe "#pass?" do
    it "returns true when score is 1.0" do
      result = described_class.new(eval_case: eval_case, actual: "a", score: 1.0, usage: nil, latency_ms: 10)
      expect(result).to be_pass
    end

    it "returns false when score is less than 1.0" do
      result = described_class.new(eval_case: eval_case, actual: "b", score: 0.0, usage: nil, latency_ms: 10)
      expect(result).not_to be_pass
    end

    it "returns false for partial scores" do
      result = described_class.new(eval_case: eval_case, actual: "b", score: 0.7, usage: nil, latency_ms: 5)
      expect(result).not_to be_pass
    end
  end

  describe "attributes" do
    it "stores all fields" do
      usage = Phronomy::TokenUsage.new(input: 10, output: 5)
      result = described_class.new(eval_case: eval_case, actual: "a", score: 1.0, usage: usage, latency_ms: 42)
      expect(result.eval_case).to eq(eval_case)
      expect(result.actual).to eq("a")
      expect(result.score).to eq(1.0)
      expect(result.usage).to eq(usage)
      expect(result.latency_ms).to eq(42)
    end

    it "defaults error to nil" do
      result = described_class.new(eval_case: eval_case, actual: "a", score: 1.0, usage: nil, latency_ms: 5)
      expect(result.error).to be_nil
    end

    it "stores an error when provided" do
      err = RuntimeError.new("scorer blew up")
      result = described_class.new(eval_case: eval_case, actual: "a", score: 0.0, usage: nil, latency_ms: 5, error: err)
      expect(result.error).to eq(err)
    end
  end

  describe "#scorer_error?" do
    it "returns false when error is nil" do
      result = described_class.new(eval_case: eval_case, actual: "a", score: 1.0, usage: nil, latency_ms: 5)
      expect(result.scorer_error?).to be false
    end

    it "returns true when error is set" do
      result = described_class.new(eval_case: eval_case, actual: "a", score: 0.0, usage: nil, latency_ms: 5, error: RuntimeError.new("boom"))
      expect(result.scorer_error?).to be true
    end
  end
end
