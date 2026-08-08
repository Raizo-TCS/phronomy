# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::LlmContextWindow::TokenBudget do
  describe "#initialize" do
    it "sets context_window and max_output_tokens" do
      budget = described_class.new(context_window: 8192, max_output_tokens: 2048)
      expect(budget.context_window).to eq(8192)
      expect(budget.max_output_tokens).to eq(2048)
    end

    it "raises when context_window is missing" do
      expect { described_class.new(max_output_tokens: 0) }
        .to raise_error(ArgumentError)
    end

    it "raises when max_output_tokens is missing" do
      expect { described_class.new(context_window: 8192) }
        .to raise_error(ArgumentError)
    end
  end

  describe "#effective_input_limit" do
    it "is context_window minus max_output_tokens" do
      budget = described_class.new(context_window: 10_000, max_output_tokens: 2_000)
      expect(budget.effective_input_limit).to eq(8_000)
    end

    it "is at least 0 when reservations exceed the window" do
      budget = described_class.new(context_window: 1_000, max_output_tokens: 2_000)
      expect(budget.effective_input_limit).to eq(0)
    end
  end

  describe "#available" do
    let(:budget) { described_class.new(context_window: 10_000, max_output_tokens: 2_000) }

    it "subtracts used tokens from effective_input_limit" do
      expect(budget.available(used: 1_000)).to eq(7_000)
    end

    it "returns 0 when used exceeds effective_input_limit" do
      expect(budget.available(used: 100_000)).to eq(0)
    end

    it "returns effective_input_limit when called without arguments" do
      expect(budget.available).to eq(budget.effective_input_limit)
    end
  end
end
