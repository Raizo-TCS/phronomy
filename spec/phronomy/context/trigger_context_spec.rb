# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Context::TriggerContext do
  def make_msg(role, content)
    OpenStruct.new(role: role, content: content)
  end

  def make_elements(pairs)
    pairs.each_with_index.map do |(role, content), idx|
      tokens = Phronomy::Context::TokenEstimator.estimate(content)
      {seq: idx, message: make_msg(role, content), tokens: tokens, role: role}
    end
  end

  let(:elements) do
    make_elements([
      [:user, "First message"],
      [:assistant, "First reply"],
      [:user, "Second message"]
    ])
  end

  let(:budget) do
    Phronomy::Context::TokenBudget.new(context_window: 2048, max_output_tokens: 256)
  end

  subject(:ctx) { described_class.new(message_elements: elements, budget: budget) }

  describe "#initialize" do
    it "exposes the budget" do
      expect(ctx.budget).to eq(budget)
    end

    it "exposes total_tokens as the sum of element tokens" do
      expected = elements.sum { |e| e[:tokens] }
      expect(ctx.total_tokens).to eq(expected)
    end

    it "exposes a frozen copy of message_elements" do
      expect(ctx.message_elements).to be_frozen
    end

    it "message_elements contains the same data" do
      expect(ctx.message_elements.map { |e| e[:seq] }).to eq([0, 1, 2])
    end
  end

  describe "immutability" do
    it "does not allow mutation of message_elements" do
      expect { ctx.message_elements << {seq: 99} }.to raise_error(FrozenError)
    end
  end

  context "with nil budget" do
    subject(:ctx) { described_class.new(message_elements: elements, budget: nil) }

    it "accepts nil budget" do
      expect(ctx.budget).to be_nil
    end
  end

  context "with empty message_elements" do
    subject(:ctx) { described_class.new(message_elements: [], budget: budget) }

    it "has zero total_tokens" do
      expect(ctx.total_tokens).to eq(0)
    end
  end
end
