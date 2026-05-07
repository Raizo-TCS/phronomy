# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Context::Builder do
  let(:budget) do
    Phronomy::Context::TokenBudget.new(context_window: 1000, max_output_tokens: 0)
  end

  def make_msg(role, content)
    OpenStruct.new(role: role, content: content)
  end

  describe "#build" do
    context "with no system text and no messages" do
      it "returns nil system and empty messages" do
        result = described_class.new(budget: budget).build
        expect(result[:system]).to be_nil
        expect(result[:messages]).to eq([])
      end
    end

    context "with system text" do
      it "includes system text in the result" do
        builder = described_class.new(budget: budget)
        builder.add_system("You are helpful.")
        result = builder.build
        expect(result[:system]).to eq("You are helpful.")
      end
    end

    context "with knowledge appended" do
      it "joins system and knowledge with double newline" do
        builder = described_class.new(budget: budget)
        builder.add_system("Role.")
        builder.add_knowledge("Fact A.")
        result = builder.build
        expect(result[:system]).to eq("Role.\n\nFact A.")
      end
    end

    context "with messages that exceed the budget" do
      it "drops oldest messages to stay within budget" do
        # budget = 1000 tokens = 4000 chars effective
        # create 10 messages each ~500 chars (125 tokens each)
        messages = Array.new(10) { |i| make_msg(:user, "x" * 500 + i.to_s) }
        builder = described_class.new(budget: budget)
        builder.add_messages(messages)
        result = builder.build
        # 1000 tokens / 125 tokens per message ≈ 8 fit
        expect(result[:messages].length).to be <= 8
        # newest messages are kept
        expect(result[:messages]).to include(messages.last)
      end
    end

    context "with messages that fit within the budget" do
      it "returns all messages" do
        messages = Array.new(3) { |i| make_msg(:user, "Hello #{i}") }
        builder = described_class.new(budget: budget)
        builder.add_messages(messages)
        result = builder.build
        expect(result[:messages].length).to eq(3)
      end
    end

    it "returns self from add_* methods for chaining" do
      builder = described_class.new(budget: budget)
      expect(builder.add_system("x")).to eq(builder)
      expect(builder.add_knowledge("k")).to eq(builder)
      expect(builder.add_messages([])).to eq(builder)
    end
  end
end
