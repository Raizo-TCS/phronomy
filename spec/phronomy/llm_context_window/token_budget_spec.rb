# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::LlmContextWindow::TokenBudget do
  describe "#initialize" do
    context "with explicit context_window" do
      it "sets context_window and defaults max_output_tokens to 0" do
        budget = described_class.new(context_window: 8192)
        expect(budget.context_window).to eq(8192)
        expect(budget.max_output_tokens).to eq(0)
      end

      it "accepts explicit max_output_tokens" do
        budget = described_class.new(context_window: 8192, max_output_tokens: 2048)
        expect(budget.max_output_tokens).to eq(2048)
      end

      it "accepts overhead" do
        budget = described_class.new(context_window: 8192, overhead: 300)
        expect(budget.overhead).to eq(300)
      end

      it "defaults overhead to 0 when not supplied" do
        budget = described_class.new(context_window: 8192)
        expect(budget.overhead).to eq(0)
      end
    end

    context "with neither model nor context_window" do
      it "raises ArgumentError" do
        expect { described_class.new }.to raise_error(ArgumentError, /model.*context_window/i)
      end
    end

    context "with an unknown model name" do
      before do
        allow(RubyLLM.models).to receive(:find).and_return(nil)
      end

      it "raises UnknownModelError" do
        expect {
          described_class.new(model: "does-not-exist")
        }.to raise_error(Phronomy::LlmContextWindow::UnknownModelError)
      end
    end

    context "when RubyLLM raises ModelNotFoundError during lookup" do
      before do
        allow(RubyLLM.models).to receive(:find).and_raise(RubyLLM::ModelNotFoundError)
      end

      it "wraps ModelNotFoundError as UnknownModelError" do
        expect {
          described_class.new(model: "some-unknown-model")
        }.to raise_error(Phronomy::LlmContextWindow::UnknownModelError)
      end
    end

    context "with a known model" do
      let(:mock_model) do
        double("model", context_window: 128_000, max_output_tokens: 16_000)
      end

      before do
        allow(RubyLLM.models).to receive(:find).with("claude-3-5-sonnet").and_return(mock_model)
      end

      it "derives context_window and max_output_tokens from the model" do
        budget = described_class.new(model: "claude-3-5-sonnet")
        expect(budget.context_window).to eq(128_000)
        expect(budget.max_output_tokens).to eq(16_000)
      end

      it "allows max_output_tokens to be overridden" do
        budget = described_class.new(model: "claude-3-5-sonnet", max_output_tokens: 4096)
        expect(budget.max_output_tokens).to eq(4096)
      end
    end
  end

  describe "#effective_input_limit" do
    it "is context_window minus max_output_tokens minus overhead" do
      budget = described_class.new(
        context_window: 10_000,
        max_output_tokens: 2_000,
        overhead: 500
      )
      expect(budget.effective_input_limit).to eq(7_500)
    end

    it "is at least 0 when reservations exceed the window" do
      budget = described_class.new(
        context_window: 1_000,
        max_output_tokens: 2_000
      )
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

    it "returns effective_input_limit when called without arguments (used defaults to 0)" do
      expect(budget.available).to eq(budget.effective_input_limit)
    end
  end
end
