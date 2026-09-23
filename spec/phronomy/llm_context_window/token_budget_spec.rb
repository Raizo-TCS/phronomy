# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::LlmContextWindow::TokenBudget do
  it "uses the full input limit without an output reserve" do
    budget = described_class.new(max_input_tokens: 128_000)
    expect(budget.max_input_tokens).to eq(128_000)
    expect(budget.effective_input_limit).to eq(128_000)
    expect(budget).not_to respond_to(:max_output_tokens)
  end

  it "subtracts used input and clamps remaining capacity at zero" do
    budget = described_class.new(max_input_tokens: 100)
    expect(budget.available).to eq(100)
    expect(budget.available(used: 30)).to eq(70)
    expect(budget.available(used: 101)).to eq(0)
  end

  it "requires a positive numeric limit" do
    [0, -1, "invalid", nil].each do |value|
      expect { described_class.new(max_input_tokens: value) }.to raise_error { |error| expect([ArgumentError, TypeError]).to include(error.class) }
    end
  end
end
