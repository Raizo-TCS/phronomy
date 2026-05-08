# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Eval::Comparison do
  let(:dataset) do
    Phronomy::Eval::Dataset.from_array([
      {input: "2+2", expected: "4"},
      {input: "3+3", expected: "6"}
    ])
  end

  # callable_a always answers correctly
  let(:callable_a) { ->(input) { input.gsub(/(\d+)\+(\d+)/) { ($1.to_i + $2.to_i).to_s } } }
  # callable_b always answers incorrectly
  let(:callable_b) { ->(_input) { "wrong" } }

  describe "#compare" do
    it "returns one ComparisonPair per EvalCase" do
      pairs = described_class.new.compare(dataset, callable_a, callable_b)
      expect(pairs.size).to eq(2)
    end

    it "pairs have the correct eval_case" do
      pairs = described_class.new.compare(dataset, callable_a, callable_b)
      expect(pairs.first.eval_case.input).to eq("2+2")
    end

    it "result_a holds the first callable's outcome" do
      pairs = described_class.new.compare(dataset, callable_a, callable_b)
      expect(pairs.first.result_a.score).to eq(1.0)
    end

    it "result_b holds the second callable's outcome" do
      pairs = described_class.new.compare(dataset, callable_a, callable_b)
      expect(pairs.first.result_b.score).to eq(0.0)
    end

    it "each pair is a ComparisonPair value object" do
      pairs = described_class.new.compare(dataset, callable_a, callable_b)
      expect(pairs).to all(be_a(Phronomy::Eval::Comparison::ComparisonPair))
    end
  end

  describe "independent Metrics for each side" do
    it "allows computing Metrics for result_a" do
      pairs = described_class.new.compare(dataset, callable_a, callable_b)
      metrics_a = Phronomy::Eval::Metrics.new(pairs.map(&:result_a))
      expect(metrics_a.pass_rate).to eq(1.0)
    end

    it "allows computing Metrics for result_b" do
      pairs = described_class.new.compare(dataset, callable_a, callable_b)
      metrics_b = Phronomy::Eval::Metrics.new(pairs.map(&:result_b))
      expect(metrics_b.pass_rate).to eq(0.0)
    end
  end
end
