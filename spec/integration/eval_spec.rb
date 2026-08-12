# frozen_string_literal: true

# Integration tests for the Evaluation framework (Issue #8).
# Group 17 — pairwise factors: eval_scorer_type × eval_dataset_size × eval_pipeline
#
# TC-001..TC-006  no LLM required (exact_match / includes_scorer)
# TC-007..TC-009  LLM required    (llm_judge with LLMStub)
#
# Run all:           bundle exec rspec spec/integration/eval_spec.rb --tag integration
# Run LLM tests:     bundle exec rspec spec/integration/eval_spec.rb --tag integration --tag llm_required
# Skip LLM tests:    bundle exec rspec spec/integration/eval_spec.rb --tag integration --tag ~llm_required

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

RSpec.describe "Evaluation framework", :integration do
  # ---------------------------------------------------------------------------
  # Callable helpers used across test cases.
  # ---------------------------------------------------------------------------

  # A callable that returns the exact expected value for each arithmetic input.
  perfect_callable = lambda do |input|
    case input
    when "What is 2 + 2?" then "4"
    when "What is 3 + 3?" then "6"
    when "What is 5 + 5?" then "10"
    else "unknown"
    end
  end

  # A callable that always returns a wrong answer.
  wrong_callable = ->(_input) { "wrong answer" }

  # A callable that returns a sentence embedding the expected value.
  verbose_callable = lambda do |input|
    num = case input
    when "What is 2 + 2?" then "4"
    when "What is 3 + 3?" then "6"
    when "What is 5 + 5?" then "10"
    else "0"
    end
    "The answer to your question is #{num}."
  end

  # ---------------------------------------------------------------------------
  # TC-001: exact_match / single / runner_only
  # ---------------------------------------------------------------------------
  it "TC-001: runs a single-case dataset with ExactMatch scorer and returns an EvalResult", :tc_001 do
    scorer = IntegrationFactors.eval_scorer("exact_match")
    dataset = IntegrationFactors.eval_dataset("single")
    runner = Phronomy::Testing::Eval::Runner.new(scorer: scorer)

    results = Timeout.timeout(90) { runner.run(dataset, perfect_callable) }

    expect(results.size).to eq(1)
    expect(results.first).to be_a(Phronomy::Testing::Eval::EvalResult)
    expect(results.first.score).to eq(1.0)
    expect(results.first).to be_pass
    expect(results.first.latency_ms).to be >= 0
  end

  # ---------------------------------------------------------------------------
  # TC-002: exact_match / multi / runner_score
  # ---------------------------------------------------------------------------
  it "TC-002: runs a multi-case dataset, scores with ExactMatch, and aggregates Metrics", :tc_002 do
    scorer = IntegrationFactors.eval_scorer("exact_match")
    dataset = IntegrationFactors.eval_dataset("multi")
    runner = Phronomy::Testing::Eval::Runner.new(scorer: scorer)

    results = Timeout.timeout(90) { runner.run(dataset, perfect_callable) }
    metrics = Phronomy::Testing::Eval::Metrics.new(results)
    summary = metrics.to_h

    expect(summary[:total]).to eq(3)
    expect(summary[:pass_count]).to eq(3)
    expect(summary[:pass_rate]).to eq(1.0)
    expect(summary[:average_score]).to eq(1.0)
    expect(summary[:average_latency_ms]).to be >= 0
  end

  # ---------------------------------------------------------------------------
  # TC-003: exact_match / single / ab_comparison
  # ---------------------------------------------------------------------------
  it "TC-003: compares two callables on a single-case dataset with ExactMatch scorer", :tc_003 do
    scorer = IntegrationFactors.eval_scorer("exact_match")
    dataset = IntegrationFactors.eval_dataset("single")
    comparison = Phronomy::Testing::Eval::Comparison.new(scorer: scorer)

    pairs = Timeout.timeout(90) { comparison.compare(dataset, perfect_callable, wrong_callable) }

    expect(pairs.size).to eq(1)
    pair = pairs.first
    expect(pair).to be_a(Phronomy::Testing::Eval::Comparison::ComparisonPair)
    expect(pair.result_a.score).to eq(1.0)
    expect(pair.result_b.score).to eq(0.0)

    metrics_a = Phronomy::Testing::Eval::Metrics.new(pairs.map(&:result_a))
    metrics_b = Phronomy::Testing::Eval::Metrics.new(pairs.map(&:result_b))
    expect(metrics_a.pass_rate).to eq(1.0)
    expect(metrics_b.pass_rate).to eq(0.0)
  end

  # ---------------------------------------------------------------------------
  # TC-004: includes_scorer / single / runner_score
  # ---------------------------------------------------------------------------
  it "TC-004: runs a single-case dataset with IncludesScorer and verifies Metrics", :tc_004 do
    scorer = IntegrationFactors.eval_scorer("includes_scorer")
    dataset = IntegrationFactors.eval_dataset("single")
    runner = Phronomy::Testing::Eval::Runner.new(scorer: scorer)

    results = Timeout.timeout(90) { runner.run(dataset, verbose_callable) }
    metrics = Phronomy::Testing::Eval::Metrics.new(results)
    summary = metrics.to_h

    expect(summary[:total]).to eq(1)
    expect(summary[:pass_count]).to eq(1)   # "The answer to your question is 4." includes "4"
    expect(summary[:pass_rate]).to eq(1.0)
  end

  # ---------------------------------------------------------------------------
  # TC-005: includes_scorer / multi / runner_only
  # ---------------------------------------------------------------------------
  it "TC-005: runs a multi-case dataset with IncludesScorer and returns correct EvalResults", :tc_005 do
    scorer = IntegrationFactors.eval_scorer("includes_scorer")
    dataset = IntegrationFactors.eval_dataset("multi")
    runner = Phronomy::Testing::Eval::Runner.new(scorer: scorer)

    results = Timeout.timeout(90) { runner.run(dataset, verbose_callable) }

    expect(results.size).to eq(3)
    expect(results).to all(be_pass)
    expect(results).to all(satisfy { |r| r.latency_ms >= 0 })
  end

  # ---------------------------------------------------------------------------
  # TC-006: includes_scorer / multi / ab_comparison
  # ---------------------------------------------------------------------------
  it "TC-006: compares two callables on a multi-case dataset with IncludesScorer", :tc_006 do
    scorer = IntegrationFactors.eval_scorer("includes_scorer")
    dataset = IntegrationFactors.eval_dataset("multi")
    comparison = Phronomy::Testing::Eval::Comparison.new(scorer: scorer)

    pairs = Timeout.timeout(90) { comparison.compare(dataset, verbose_callable, wrong_callable) }

    expect(pairs.size).to eq(3)
    # verbose_callable: all 3 should pass (sentence includes the number)
    metrics_a = Phronomy::Testing::Eval::Metrics.new(pairs.map(&:result_a))
    expect(metrics_a.pass_rate).to eq(1.0)
    # wrong_callable: 0 should pass ("wrong answer" does not include "4", "6", or "10")
    metrics_b = Phronomy::Testing::Eval::Metrics.new(pairs.map(&:result_b))
    expect(metrics_b.pass_rate).to eq(0.0)
  end

  # ---------------------------------------------------------------------------
  # TC-007: llm_judge / single / runner_only   [LLM_REQUIRED]
  # ---------------------------------------------------------------------------
  it "TC-007: runs a single-case dataset with LlmJudge scorer and returns a numeric score", :tc_007, :llm_required do
    LLMStub.activate(responses: ["score: 0.9\nreason: The answer 4 is correct."])
    scorer = IntegrationFactors.eval_scorer("llm_judge")
    dataset = IntegrationFactors.eval_dataset("single")
    runner = Phronomy::Testing::Eval::Runner.new(scorer: scorer)

    results = Timeout.timeout(90) { runner.run(dataset, perfect_callable) }

    expect(results.size).to eq(1)
    score = results.first.score
    expect(score).to be_a(Float)
    expect(score).to be_between(0.0, 1.0)
  ensure
    LLMStub.deactivate
  end

  # ---------------------------------------------------------------------------
  # TC-008: llm_judge / multi / runner_score   [LLM_REQUIRED]
  # ---------------------------------------------------------------------------
  it "TC-008: runs a multi-case dataset with LlmJudge and verifies Metrics aggregation", :tc_008, :llm_required do
    LLMStub.activate(responses: ["score: 0.9\nreason: correct"])
    scorer = IntegrationFactors.eval_scorer("llm_judge")
    dataset = IntegrationFactors.eval_dataset("multi")
    runner = Phronomy::Testing::Eval::Runner.new(scorer: scorer)

    results = Timeout.timeout(90) { runner.run(dataset, perfect_callable) }
    metrics = Phronomy::Testing::Eval::Metrics.new(results)
    summary = metrics.to_h

    expect(summary[:total]).to eq(3)
    expect(summary[:average_score]).to be_between(0.0, 1.0)
    expect(summary[:average_latency_ms]).to be >= 0
  ensure
    LLMStub.deactivate
  end

  # ---------------------------------------------------------------------------
  # TC-009: llm_judge / single / ab_comparison  [LLM_REQUIRED]
  # ---------------------------------------------------------------------------
  it "TC-009: compares two callables on a single-case dataset with LlmJudge scorer", :tc_009, :llm_required do
    LLMStub.activate(responses: ["score: 0.9\nreason: correct", "score: 0.1\nreason: wrong answer"])
    scorer = IntegrationFactors.eval_scorer("llm_judge")
    dataset = IntegrationFactors.eval_dataset("single")
    comparison = Phronomy::Testing::Eval::Comparison.new(scorer: scorer)

    pairs = Timeout.timeout(90) { comparison.compare(dataset, perfect_callable, wrong_callable) }

    expect(pairs.size).to eq(1)
    expect(pairs.first.result_a.score).to be_between(0.0, 1.0)
    expect(pairs.first.result_b.score).to be_between(0.0, 1.0)
    # perfect callable should score higher than wrong callable
    expect(pairs.first.result_a.score).to be >= pairs.first.result_b.score
  ensure
    LLMStub.deactivate
  end
end
