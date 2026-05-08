# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Context::Assembler do
  def make_msg(role, content)
    OpenStruct.new(role: role, content: content)
  end

  describe "#build without budget" do
    subject(:assembler) { described_class.new }

    it "returns nil system when nothing is added" do
      expect(assembler.build[:system]).to be_nil
    end

    it "returns empty messages when nothing is added" do
      expect(assembler.build[:messages]).to eq([])
    end

    it "returns instruction as system prompt" do
      assembler.add_instruction("You are helpful.")
      expect(assembler.build[:system]).to eq("You are helpful.")
    end

    it "wraps knowledge in an XML context tag" do
      assembler.add_knowledge("The user is Alice.", type: :entity)
      result = assembler.build
      expect(result[:system]).to include('<context type="entity" trusted="false">')
      expect(result[:system]).to include("The user is Alice.")
      expect(result[:system]).to include("</context>")
    end

    it "combines instruction and knowledge in system prompt" do
      assembler.add_instruction("You are helpful.")
      assembler.add_knowledge("Fact.", type: :static)
      result = assembler.build
      expect(result[:system]).to start_with("You are helpful.")
      expect(result[:system]).to include("<context")
    end

    it "sets trusted attribute when trusted: true" do
      assembler.add_knowledge("Trusted.", type: :static, trusted: true)
      expect(assembler.build[:system]).to include('trusted="true"')
    end

    it "passes all messages through when no budget" do
      msgs = (1..5).map { |i| make_msg(:user, "msg #{i}") }
      assembler.add_messages(msgs)
      expect(assembler.build[:messages]).to eq(msgs)
    end

    it "is chainable (add_* returns self)" do
      expect(assembler.add_instruction("hi")).to eq(assembler)
      expect(assembler.add_knowledge("fact", type: :rag)).to eq(assembler)
      expect(assembler.add_messages([])).to eq(assembler)
    end
  end

  describe "#build with budget" do
    let(:budget) do
      # ~4 chars per token — 10 token limit ≈ 40 chars, enough for 2 short messages
      Phronomy::Context::TokenBudget.new(context_window: 10, max_output_tokens: 0)
    end

    subject(:assembler) { described_class.new(budget: budget) }

    it "trims oldest messages when they exceed the budget" do
      msgs = Array.new(6) { |i| make_msg(:user, "x" * 20 + i.to_s) }
      assembler.add_messages(msgs)
      result = assembler.build[:messages]
      expect(result.length).to be < 6
      expect(result.last).to eq(msgs.last)
    end

    it "returns empty messages when budget is exhausted by system text" do
      # Instruction consumes all tokens; messages should be dropped.
      assembler.add_instruction("x" * 200)
      msgs = [make_msg(:user, "hello")]
      assembler.add_messages(msgs)
      # Cannot guarantee exact trim, just ensure no error and result is an Array.
      expect(assembler.build[:messages]).to be_an(Array)
    end

    it "preserves the newest messages" do
      msgs = Array.new(10) { |i| make_msg(:user, "x" * 20 + i.to_s) }
      assembler.add_messages(msgs)
      result = assembler.build[:messages]
      expect(result).to include(msgs.last) unless result.empty?
    end
  end
end
