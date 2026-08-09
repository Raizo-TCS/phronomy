# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::LlmContextWindow::TokenBudget do
  describe "#initialize" do
    it "stores explicit context_window and max_output_tokens" do
      budget = described_class.new(
        context_window: 8_192,
        max_output_tokens: 2_048
      )

      expect(budget.context_window).to eq(8_192)
      expect(budget.max_output_tokens).to eq(2_048)
    end

    it "requires both numeric values" do
      expect {
        described_class.new(context_window: 8_192, max_output_tokens: nil)
      }.to raise_error(TypeError)
    end

    it "does not expose the removed overhead compatibility field" do
      budget = described_class.new(
        context_window: 8_192,
        max_output_tokens: 2_048
      )

      expect(budget).not_to respond_to(:overhead)
    end
  end

  describe "#effective_input_limit" do
    it "is context_window minus max_output_tokens" do
      budget = described_class.new(
        context_window: 10_000,
        max_output_tokens: 2_000
      )

      expect(budget.effective_input_limit).to eq(8_000)
    end

    it "is clamped at zero" do
      budget = described_class.new(
        context_window: 1_000,
        max_output_tokens: 2_000
      )

      expect(budget.effective_input_limit).to eq(0)
    end
  end

  describe "#available" do
    let(:budget) do
      described_class.new(
        context_window: 10_000,
        max_output_tokens: 2_000
      )
    end

    it "subtracts used tokens from effective_input_limit" do
      expect(budget.available(used: 1_000)).to eq(7_000)
    end

    it "returns zero when used exceeds the input limit" do
      expect(budget.available(used: 100_000)).to eq(0)
    end

    it "defaults used to zero" do
      expect(budget.available).to eq(8_000)
    end
  end
end
