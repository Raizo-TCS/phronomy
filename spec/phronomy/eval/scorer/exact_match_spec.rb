# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Eval::Scorer::ExactMatch do
  subject(:scorer) { described_class.new }

  describe "#score" do
    it "returns 1.0 for identical strings" do
      expect(scorer.score(actual: "Paris", expected: "Paris")).to eq(1.0)
    end

    it "returns 0.0 for different strings" do
      expect(scorer.score(actual: "London", expected: "Paris")).to eq(0.0)
    end

    it "strips leading and trailing whitespace before comparing" do
      expect(scorer.score(actual: "  Paris  ", expected: "Paris")).to eq(1.0)
    end

    it "is case-sensitive by default" do
      expect(scorer.score(actual: "paris", expected: "Paris")).to eq(0.0)
    end

    it "accepts an optional input keyword (ignored)" do
      expect(scorer.score(actual: "4", expected: "4", input: "2+2")).to eq(1.0)
    end
  end

  describe "case_sensitive: false" do
    subject(:ci_scorer) { described_class.new(case_sensitive: false) }

    it "returns 1.0 regardless of case" do
      expect(ci_scorer.score(actual: "paris", expected: "PARIS")).to eq(1.0)
    end
  end
end
