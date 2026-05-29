# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Eval::Scorer::IncludesScorer do
  subject(:scorer) { described_class.new }

  describe "#score" do
    it "returns 1.0 when actual contains expected" do
      expect(scorer.score(actual: "The answer is 42.", expected: "42")).to eq(1.0)
    end

    it "returns 0.0 when actual does not contain expected" do
      expect(scorer.score(actual: "The answer is 42.", expected: "Paris")).to eq(0.0)
    end

    it "is case-insensitive by default" do
      expect(scorer.score(actual: "PARIS is beautiful", expected: "paris")).to eq(1.0)
    end

    it "normalises expected to lowercase (UPPER expected matches lower actual)" do
      expect(scorer.score(actual: "paris is beautiful", expected: "PARIS")).to eq(1.0)
    end

    it "handles exact substrings at boundaries" do
      expect(scorer.score(actual: "yes", expected: "yes")).to eq(1.0)
    end

    it "accepts an optional input keyword (ignored)" do
      expect(scorer.score(actual: "4", expected: "4", input: "2+2")).to eq(1.0)
    end

    it "converts actual to String via to_s" do
      expect(scorer.score(actual: 42, expected: "42")).to eq(1.0)
    end

    it "converts expected to String via to_s" do
      expect(scorer.score(actual: "The answer is 42", expected: 42)).to eq(1.0)
    end

    context "when case_sensitive: true" do
      subject(:cs_scorer) { described_class.new(case_sensitive: true) }

      it "returns 0.0 when case does not match" do
        expect(cs_scorer.score(actual: "PARIS is great", expected: "aris")).to eq(0.0)
      end

      it "returns 1.0 when case matches" do
        expect(cs_scorer.score(actual: "PARIS is great", expected: "PARIS")).to eq(1.0)
      end
    end
  end

  describe "case_sensitive: true" do
    subject(:cs_scorer) { described_class.new(case_sensitive: true) }

    it "returns 0.0 when case does not match" do
      expect(cs_scorer.score(actual: "PARIS", expected: "paris")).to eq(0.0)
    end

    it "returns 1.0 when case matches" do
      expect(cs_scorer.score(actual: "PARIS is great", expected: "PARIS")).to eq(1.0)
    end
  end

  describe "case-insensitive default — expected normalisation" do
    it "normalises expected to lowercase so UPPER expected matches lower actual" do
      expect(scorer.score(actual: "paris is beautiful", expected: "PARIS")).to eq(1.0)
    end

    it "returns 0.0 when the normalised strings do not overlap" do
      expect(scorer.score(actual: "berlin is beautiful", expected: "PARIS")).to eq(0.0)
    end
  end
end
