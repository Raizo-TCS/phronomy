# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Eval::Metrics do
  let(:eval_case) { Phronomy::Eval::EvalCase.new(input: "q", expected: "a") }

  def make_result(score:, usage: nil, latency_ms: 10)
    Phronomy::Eval::EvalResult.new(eval_case: eval_case, actual: "a", score: score, usage: usage, latency_ms: latency_ms)
  end

  describe "#pass_rate" do
    it "returns 1.0 when all results pass" do
      metrics = described_class.new([make_result(score: 1.0), make_result(score: 1.0)])
      expect(metrics.pass_rate).to eq(1.0)
    end

    it "returns 0.5 for half passing" do
      metrics = described_class.new([make_result(score: 1.0), make_result(score: 0.0)])
      expect(metrics.pass_rate).to eq(0.5)
    end

    it "returns 0.0 for an empty result set" do
      expect(described_class.new([]).pass_rate).to eq(0.0)
    end
  end

  describe "#average_score" do
    it "averages the scores" do
      metrics = described_class.new([make_result(score: 0.8), make_result(score: 0.4)])
      expect(metrics.average_score).to be_within(0.001).of(0.6)
    end

    it "returns 0.0 for an empty result set" do
      expect(described_class.new([]).average_score).to eq(0.0)
    end
  end

  describe "#total_usage" do
    it "sums TokenUsage across results" do
      u1 = Phronomy::TokenUsage.new(input: 10, output: 5)
      u2 = Phronomy::TokenUsage.new(input: 20, output: 10)
      metrics = described_class.new([make_result(score: 1.0, usage: u1), make_result(score: 1.0, usage: u2)])
      total = metrics.total_usage
      expect(total.input).to eq(30)
      expect(total.output).to eq(15)
    end

    it "skips results with nil usage" do
      u1 = Phronomy::TokenUsage.new(input: 5, output: 3)
      metrics = described_class.new([make_result(score: 1.0, usage: u1), make_result(score: 1.0, usage: nil)])
      expect(metrics.total_usage.input).to eq(5)
    end

    it "returns TokenUsage.zero when no usage is recorded" do
      metrics = described_class.new([make_result(score: 1.0)])
      expect(metrics.total_usage).to eq(Phronomy::TokenUsage.zero)
    end
  end

  describe "#average_latency_ms" do
    it "averages latency values" do
      metrics = described_class.new([make_result(score: 1.0, latency_ms: 20), make_result(score: 1.0, latency_ms: 40)])
      expect(metrics.average_latency_ms).to be_within(0.001).of(30.0)
    end

    it "returns 0.0 for an empty result set" do
      expect(described_class.new([]).average_latency_ms).to eq(0.0)
    end
  end

  describe "#to_h" do
    it "includes all summary keys" do
      metrics = described_class.new([make_result(score: 1.0), make_result(score: 0.0)])
      h = metrics.to_h
      expect(h).to include(:total, :pass_count, :pass_rate, :average_score, :total_usage, :average_latency_ms)
    end

    it "reports correct total and pass_count" do
      metrics = described_class.new([make_result(score: 1.0), make_result(score: 0.0)])
      h = metrics.to_h
      expect(h[:total]).to eq(2)
      expect(h[:pass_count]).to eq(1)
    end
  end
end
