# frozen_string_literal: true

require_relative "spec_helper"

# Group 3: Context / Budget
# Tests exercise TokenBudget and TokenEstimator directly without invoking an LLM.
# Assembler (deleted in Phase 1/2 cleanup) and model-registry lookup tests have
# been removed; TokenBudgetResolver now owns model lookup.
# The :integration tag is kept for consistency.

RSpec.describe "Group 3: Context / Budget", :integration do
  # ---------------------------------------------------------------------------
  # TC-002: word-count tokenizer; TokenBudget with explicit budget
  # ---------------------------------------------------------------------------
  describe "TC-002: word-count tokenizer via TokenEstimator; explicit TokenBudget" do
    around do |example|
      original = Phronomy::LlmContextWindow::TokenEstimator.tokenizer
      Phronomy::LlmContextWindow::TokenEstimator.tokenizer = ->(text) { text.split.length }
      example.run
    ensure
      Phronomy::LlmContextWindow::TokenEstimator.tokenizer = original
    end

    it "uses word-count tokenizer via TokenEstimator" do
      count = Phronomy::LlmContextWindow::TokenEstimator.estimate("hello world foo bar")
      expect(count).to eq(4)
    end

    it "TokenBudget effective_input_limit equals context_window minus max_output_tokens" do
      budget = Phronomy::LlmContextWindow::TokenBudget.new(
        context_window: 200,
        max_output_tokens: 50
      )
      expect(budget.effective_input_limit).to eq(150)
    end
  end

  # TC-003 infeasible (tiktoken)
  # TC-004 infeasible (tiktoken)

  # ---------------------------------------------------------------------------
  # TC-005: explicit small budget; effective_input_limit and available
  # ---------------------------------------------------------------------------
  describe "TC-005: explicit budget; effective_input_limit and available" do
    it "effective_input_limit returns context_window minus max_output_tokens" do
      budget = Phronomy::LlmContextWindow::TokenBudget.new(
        context_window: 100,
        max_output_tokens: 50
      )
      expect(budget.effective_input_limit).to eq(50)
    end

    it "available(used:) returns remaining capacity after subtracting used tokens" do
      budget = Phronomy::LlmContextWindow::TokenBudget.new(
        context_window: 100,
        max_output_tokens: 50
      )
      expect(budget.available(used: 30)).to eq(20)
    end

    it "available clamps to zero when used exceeds effective_input_limit" do
      budget = Phronomy::LlmContextWindow::TokenBudget.new(
        context_window: 100,
        max_output_tokens: 50
      )
      expect(budget.available(used: 60)).to eq(0)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: explicit budget; large max_output; word-count tokenizer
  # ---------------------------------------------------------------------------
  describe "TC-006: explicit budget; large max_output; word-count tokenizer" do
    around do |example|
      original = Phronomy::LlmContextWindow::TokenEstimator.tokenizer
      Phronomy::LlmContextWindow::TokenEstimator.tokenizer = ->(text) { text.split.length }
      example.run
    ensure
      Phronomy::LlmContextWindow::TokenEstimator.tokenizer = original
    end

    it "effective_input_limit is small when max_output_tokens is large" do
      budget = Phronomy::LlmContextWindow::TokenBudget.new(
        context_window: 500,
        max_output_tokens: 400
      )
      expect(budget.effective_input_limit).to eq(100)
    end

    it "word-count tokenizer estimates 8 tokens for an 8-word message" do
      count = Phronomy::LlmContextWindow::TokenEstimator.estimate("a b c d e f g h")
      expect(count).to eq(8)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-007: explicit budget; effective_input_limit clamping behaviour
  # ---------------------------------------------------------------------------
  describe "TC-007: explicit budget; word-count tokenizer; effective_input_limit behaviour" do
    around do |example|
      original = Phronomy::LlmContextWindow::TokenEstimator.tokenizer
      Phronomy::LlmContextWindow::TokenEstimator.tokenizer = ->(text) { text.split.length }
      example.run
    ensure
      Phronomy::LlmContextWindow::TokenEstimator.tokenizer = original
    end

    it "effective_input_limit equals context_window when max_output_tokens is zero" do
      budget = Phronomy::LlmContextWindow::TokenBudget.new(
        context_window: 10_000,
        max_output_tokens: 0
      )
      expect(budget.effective_input_limit).to eq(10_000)
    end

    it "effective_input_limit clamps to zero when max_output_tokens exceeds context_window" do
      budget = Phronomy::LlmContextWindow::TokenBudget.new(
        context_window: 100,
        max_output_tokens: 200
      )
      expect(budget.effective_input_limit).to eq(0)
    end
  end

  # TC-008 infeasible (tiktoken + unknown_model)
  # TC-009..TC-012: model-registry lookup removed from TokenBudget (moved to TokenBudgetResolver)
  # TC-013 infeasible (tiktoken)
  # TC-014..TC-016: model: keyword removed from TokenBudget
  # TC-018 infeasible (tiktoken)

  # ---------------------------------------------------------------------------
  # TC-017: word-count tokenizer; large context_window; zero max_output_tokens
  # ---------------------------------------------------------------------------
  describe "TC-017: word-count tokenizer; large context_window; zero max_output_tokens" do
    around do |example|
      original = Phronomy::LlmContextWindow::TokenEstimator.tokenizer
      Phronomy::LlmContextWindow::TokenEstimator.tokenizer = ->(text) { text.split.length }
      example.run
    ensure
      Phronomy::LlmContextWindow::TokenEstimator.tokenizer = original
    end

    it "word-count tokenizer is used by TokenEstimator" do
      expect(Phronomy::LlmContextWindow::TokenEstimator.estimate("one two three")).to eq(3)
    end

    it "effective_input_limit equals context_window when max_output_tokens is zero" do
      budget = Phronomy::LlmContextWindow::TokenBudget.new(
        context_window: 50_000,
        max_output_tokens: 0
      )
      expect(budget.effective_input_limit).to eq(50_000)
    end
  end
end
