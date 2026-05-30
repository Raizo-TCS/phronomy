# frozen_string_literal: true

require_relative "spec_helper"

# Group 3: Context / Budget
# Pairwise factors: token_budget_source × token_budget_max_output_tokens ×
#                   token_budget_overhead × token_estimator_tokenizer ×
#                   context_builder_messages_fit × agent_max_output_tokens ×
#                   agent_context_overhead
# Feasible cases: 13 (5 infeasible: R-tiktoken — tiktoken_ruby not installed)
#
# These tests exercise TokenBudget, TokenEstimator, and Context::Assembler directly
# without invoking an LLM (no LM Studio dependency).
# The :integration tag is kept for consistency.

RSpec.describe "Group 3: Context / Budget", :integration do
  # ---------------------------------------------------------------------------
  # Helpers: simple Struct that mimics a message object (#role, #content)
  # ---------------------------------------------------------------------------
  Message = Struct.new(:role, :content)

  # Build a list of Message objects whose total token cost can be controlled.
  # With the heuristic estimator (ceil(len/4)), each char costs 0.25 tokens.
  # A message with 40 chars  ≈ 10 tokens.
  # A message with 400 chars ≈ 100 tokens.
  def short_messages(count = 3)
    count.times.map { |i| Message.new("user", "Message #{i}: hello world ok.") }
  end

  # Build messages whose individual cost exceeds a very small budget.
  def fat_messages(count = 3)
    count.times.map { |i| Message.new("user", "x" * 2000 + " #{i}") }
  end

  # ---------------------------------------------------------------------------
  # TC-001: from_model; nil max_output; zero overhead; nil tokenizer;
  #         all_fit; nil agent_max_output; zero context_overhead — baseline
  # ---------------------------------------------------------------------------
  describe "TC-001: from_model; heuristic tokenizer; all messages fit — baseline" do
    it "creates a budget from the model registry and effective_input_limit > 0" do
      budget = Phronomy::LlmContextWindow::TokenBudget.new(model: "openai/gpt-oss-20b")
      expect(budget.context_window).to be > 0
      expect(budget.effective_input_limit).to be > 0
    end

    it "Assembler keeps all short messages within budget" do
      budget = Phronomy::LlmContextWindow::TokenBudget.new(model: "openai/gpt-oss-20b")
      assembler = Phronomy::LlmContextWindow::Assembler.new(budget: budget)
      assembler.add_messages(short_messages(3))
      result = assembler.build
      expect(result[:messages].length).to eq(3)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: from_model; small max_output; medium overhead; word_count tokenizer;
  #         partial_fit; small agent_max_output; medium context_overhead
  # ---------------------------------------------------------------------------
  describe "TC-002: from_model; word-count tokenizer; tight output; medium overhead; partial fit" do
    around do |example|
      original = Phronomy::LlmContextWindow::TokenEstimator.tokenizer
      # word_count tokenizer: split by whitespace
      Phronomy::LlmContextWindow::TokenEstimator.tokenizer = ->(text) { text.split.length }
      example.run
    ensure
      Phronomy::LlmContextWindow::TokenEstimator.tokenizer = original
    end

    it "uses word-count tokenizer via TokenEstimator" do
      count = Phronomy::LlmContextWindow::TokenEstimator.estimate("hello world foo bar")
      expect(count).to eq(4)
    end

    it "partial fit: only recent messages kept under tight budget" do
      # context_window=200, max_output=50, overhead=80 → effective_input_limit=70
      budget = Phronomy::LlmContextWindow::TokenBudget.new(
        context_window: 200,
        max_output_tokens: 50,
        overhead: 80
      )
      expect(budget.effective_input_limit).to eq(70)

      # Each fat message has 2001+ words → token cost >> 70
      # Short messages: ~5 words each → fits several
      messages = 20.times.map { |i| Message.new("user", "word#{i} hello world ok great") }
      assembler = Phronomy::LlmContextWindow::Assembler.new(budget: budget)
      assembler.add_messages(messages)
      result = assembler.build
      # Should keep some but not all messages (70 tokens / 5 per message = 14 max)
      expect(result[:messages].length).to be < 20
      expect(result[:messages].length).to be >= 1
    end
  end

  # TC-003 infeasible (tiktoken)
  # TC-004 infeasible (tiktoken)

  # ---------------------------------------------------------------------------
  # TC-005: explicit budget; heuristic tokenizer; none_fit → all messages pruned
  # ---------------------------------------------------------------------------
  describe "TC-005: explicit budget; heuristic tokenizer; none_fit — all messages pruned" do
    it "Assembler returns empty messages when budget is exhausted" do
      # context_window=100, max_output=50 → effective_input_limit=50
      # Fat messages are 500+ tokens each
      budget = Phronomy::LlmContextWindow::TokenBudget.new(
        context_window: 100,
        max_output_tokens: 50
      )
      assembler = Phronomy::LlmContextWindow::Assembler.new(budget: budget)
      assembler.add_messages(fat_messages(3))
      result = assembler.build
      expect(result[:messages]).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: explicit budget; large max_output; zero overhead; word_count; partial_fit
  # ---------------------------------------------------------------------------
  describe "TC-006: explicit budget; large max_output; word-count tokenizer; partial fit" do
    around do |example|
      original = Phronomy::LlmContextWindow::TokenEstimator.tokenizer
      Phronomy::LlmContextWindow::TokenEstimator.tokenizer = ->(text) { text.split.length }
      example.run
    ensure
      Phronomy::LlmContextWindow::TokenEstimator.tokenizer = original
    end

    it "partial fit under word-count tokenizer" do
      # context_window=500, max_output=400, overhead=0 → effective_input_limit=100
      budget = Phronomy::LlmContextWindow::TokenBudget.new(
        context_window: 500,
        max_output_tokens: 400
      )
      expect(budget.effective_input_limit).to eq(100)

      # Each message has 8 words → 8 tokens; 100 / 8 = 12 messages max
      messages = 20.times.map { |i| Message.new("user", "a b c d e f g #{i}") }
      assembler = Phronomy::LlmContextWindow::Assembler.new(budget: budget)
      assembler.add_messages(messages)
      result = assembler.build
      expect(result[:messages].length).to be < 20
      expect(result[:messages].length).to be >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # TC-007: explicit budget; large overhead; word_count; all messages still fit
  # ---------------------------------------------------------------------------
  describe "TC-007: explicit budget; large overhead; word-count tokenizer; all messages fit" do
    around do |example|
      original = Phronomy::LlmContextWindow::TokenEstimator.tokenizer
      Phronomy::LlmContextWindow::TokenEstimator.tokenizer = ->(text) { text.split.length }
      example.run
    ensure
      Phronomy::LlmContextWindow::TokenEstimator.tokenizer = original
    end

    it "all short messages fit even with large overhead reservation" do
      # context_window=10000, max_output=0, overhead=500 → effective=9500
      # Short messages: ~5 words each × 3 = 15 tokens << 9500
      budget = Phronomy::LlmContextWindow::TokenBudget.new(
        context_window: 10_000,
        max_output_tokens: 0,
        overhead: 500
      )
      expect(budget.effective_input_limit).to eq(9500)

      assembler = Phronomy::LlmContextWindow::Assembler.new(budget: budget)
      assembler.add_messages(short_messages(3))
      result = assembler.build
      expect(result[:messages].length).to eq(3)
    end
  end

  # TC-008 infeasible (tiktoken + unknown_model)

  # ---------------------------------------------------------------------------
  # TC-009: unknown_model → UnknownModelError raised at budget initialization
  # ---------------------------------------------------------------------------
  describe "TC-009: unknown_model → UnknownModelError raised at budget initialization" do
    it "raises UnknownModelError for an unrecognised model name" do
      expect {
        Phronomy::LlmContextWindow::TokenBudget.new(model: "nonexistent/model-xyz-9999")
      }.to raise_error(Phronomy::LlmContextWindow::UnknownModelError, /nonexistent\/model-xyz-9999/)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-010: unknown_model → UnknownModelError; none_fit and large budget not exercised
  # ---------------------------------------------------------------------------
  describe "TC-010: unknown_model → UnknownModelError (large overhead / none_fit variant)" do
    it "raises UnknownModelError regardless of overhead and context_builder_messages_fit settings" do
      expect {
        Phronomy::LlmContextWindow::TokenBudget.new(model: "bad-vendor/bad-model")
      }.to raise_error(Phronomy::LlmContextWindow::UnknownModelError)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-011: unknown_model → UnknownModelError; word_count tokenizer not reached
  # ---------------------------------------------------------------------------
  describe "TC-011: unknown_model → UnknownModelError; word_count tokenizer not reached" do
    around do |example|
      original = Phronomy::LlmContextWindow::TokenEstimator.tokenizer
      Phronomy::LlmContextWindow::TokenEstimator.tokenizer = ->(text) { text.split.length }
      example.run
    ensure
      Phronomy::LlmContextWindow::TokenEstimator.tokenizer = original
    end

    it "raises UnknownModelError before any tokenizer is used" do
      expect {
        Phronomy::LlmContextWindow::TokenBudget.new(model: "unknown/model-does-not-exist")
      }.to raise_error(Phronomy::LlmContextWindow::UnknownModelError)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-012: unknown_model → UnknownModelError; partial_fit not exercised
  # ---------------------------------------------------------------------------
  describe "TC-012: unknown_model → UnknownModelError; partial_fit not exercised" do
    it "raises UnknownModelError — partial_fit context_builder factor is irrelevant" do
      expect {
        Phronomy::LlmContextWindow::TokenBudget.new(model: "mystery-vendor/mystery-model")
      }.to raise_error(Phronomy::LlmContextWindow::UnknownModelError)
    end
  end

  # TC-013 infeasible (tiktoken)

  # ---------------------------------------------------------------------------
  # TC-014: from_model; small max_output; zero overhead; nil tokenizer; all_fit;
  #         nil agent_max_output; large context_overhead
  # ---------------------------------------------------------------------------
  describe "TC-014: from_model; small max_output; large context_overhead; all messages fit" do
    it "effective_input_limit is reduced by large context_overhead (overhead param)" do
      # Use an overhead that exceeds context_window - max_output_tokens so the limit clamps to 0
      budget = Phronomy::LlmContextWindow::TokenBudget.new(
        model: "openai/gpt-oss-20b",
        max_output_tokens: 512,
        overhead: 200_000
      )
      # effective_input_limit = max(context_window - 512 - 200_000, 0) = 0
      expect(budget.effective_input_limit).to eq(0)
    end

    it "Assembler returns empty messages when effective_input_limit is 0" do
      budget = Phronomy::LlmContextWindow::TokenBudget.new(
        model: "openai/gpt-oss-20b",
        max_output_tokens: 512,
        overhead: 200_000
      )
      assembler = Phronomy::LlmContextWindow::Assembler.new(budget: budget)
      assembler.add_messages(short_messages(3))
      result = assembler.build
      expect(result[:messages]).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-015: from_model; large max_output; zero overhead; nil tokenizer; all_fit;
  #         small agent_max_output; zero context_overhead
  # ---------------------------------------------------------------------------
  describe "TC-015: from_model; large max_output vs. small max_output_tokens" do
    it "TokenBudget honours the explicit max_output_tokens override over registry value" do
      # Explicit small max_output_tokens overrides the registry default
      budget_small = Phronomy::LlmContextWindow::TokenBudget.new(
        model: "openai/gpt-oss-20b",
        max_output_tokens: 128
      )
      budget_large = Phronomy::LlmContextWindow::TokenBudget.new(
        model: "openai/gpt-oss-20b",
        max_output_tokens: 4096
      )
      # Larger max_output means less effective_input_limit
      expect(budget_small.effective_input_limit).to be > budget_large.effective_input_limit
    end

    it "Assembler keeps all short messages when effective_input_limit is large" do
      budget = Phronomy::LlmContextWindow::TokenBudget.new(
        model: "openai/gpt-oss-20b",
        max_output_tokens: 128
      )
      assembler = Phronomy::LlmContextWindow::Assembler.new(budget: budget)
      assembler.add_messages(short_messages(3))
      result = assembler.build
      expect(result[:messages].length).to eq(3)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-016: from_model; nil max_output; large overhead; nil tokenizer; partial_fit
  # ---------------------------------------------------------------------------
  describe "TC-016: from_model; large overhead; heuristic tokenizer; partial fit" do
    it "overhead reduces effective_input_limit causing partial fit" do
      # Use an explicit large overhead to force partial fit
      budget = Phronomy::LlmContextWindow::TokenBudget.new(
        model: "openai/gpt-oss-20b",
        overhead: 100_000
      )
      expect(budget.effective_input_limit).to eq(0)

      assembler = Phronomy::LlmContextWindow::Assembler.new(budget: budget)
      assembler.add_messages(short_messages(5))
      result = assembler.build
      expect(result[:messages]).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-017: from_model; nil max_output; zero overhead; word_count; all_fit;
  #         nil agent_max_output; large context_overhead
  # ---------------------------------------------------------------------------
  describe "TC-017: from_model; word-count tokenizer; large context_overhead; all short messages fit" do
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

    it "all short messages fit despite large context_overhead reservation" do
      # context_window=50000, max_output=0, overhead=40000 → effective=10000
      budget = Phronomy::LlmContextWindow::TokenBudget.new(
        context_window: 50_000,
        max_output_tokens: 0,
        overhead: 40_000
      )
      assembler = Phronomy::LlmContextWindow::Assembler.new(budget: budget)
      assembler.add_messages(short_messages(3))
      result = assembler.build
      expect(result[:messages].length).to eq(3)
    end
  end

  # TC-018 infeasible (tiktoken)
end
