# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Eval::Runner do
  let(:dataset) do
    Phronomy::Eval::Dataset.from_array([
      {input: "2+2", expected: "4"},
      {input: "3+3", expected: "6"}
    ])
  end

  describe "#run with a plain-string callable" do
    let(:callable) { ->(input) { input.gsub(/\d+\+\d+/) { |m| eval(m).to_s } } } # rubocop:disable Security/Eval

    it "returns one EvalResult per EvalCase" do
      results = described_class.new.run(dataset, callable)
      expect(results.size).to eq(2)
    end

    it "stores the actual output" do
      results = described_class.new.run(dataset, callable)
      expect(results.first.actual).to eq("4")
    end

    it "scores using ExactMatch by default" do
      results = described_class.new.run(dataset, callable)
      expect(results.all?(&:pass?)).to be true
    end

    it "sets usage to nil when callable returns a String" do
      results = described_class.new.run(dataset, callable)
      expect(results.map(&:usage)).to all(be_nil)
    end

    it "records latency_ms as a non-negative number" do
      results = described_class.new.run(dataset, callable)
      expect(results).to all(satisfy { |r| r.latency_ms >= 0 })
    end
  end

  describe "#run with a Hash-returning callable" do
    let(:usage) { Phronomy::TokenUsage.new(input: 10, output: 5) }
    let(:callable) { ->(input) { {output: "4", usage: usage} } }

    it "extracts the output from :output key" do
      results = described_class.new.run(dataset, callable)
      expect(results.first.actual).to eq("4")
    end

    it "stores usage from the :usage key" do
      results = described_class.new.run(dataset, callable)
      expect(results.first.usage).to eq(usage)
    end
  end

  describe "#run with a custom scorer" do
    it "uses the provided scorer" do
      scorer = Phronomy::Eval::Scorer::IncludesScorer.new
      runner = described_class.new(scorer: scorer)
      callable = ->(_input) { "The answer is 4." }

      results = runner.run(dataset, callable)
      expect(results.first.score).to eq(1.0)  # "The answer is 4." includes "4"
      expect(results.last.score).to eq(0.0)   # does not include "6"
    end
  end

  describe "#run with a failing callable" do
    it "propagates errors from the callable" do
      callable = ->(_input) { raise "boom" }
      expect { described_class.new.run(dataset, callable) }.to raise_error(RuntimeError, "boom")
    end
  end
end
