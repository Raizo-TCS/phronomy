# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Context::TokenEstimator do
  describe ".estimate" do
    context "with a String" do
      it "returns 0 for an empty string" do
        expect(described_class.estimate("")).to eq(0)
      end

      it "returns ceil(length / 4) for ASCII text" do
        expect(described_class.estimate("abcd")).to eq(1)
        expect(described_class.estimate("abcde")).to eq(2)
        expect(described_class.estimate("a" * 400)).to eq(100)
      end
    end

    context "with an Array of message-like objects" do
      let(:msg1) { double("msg", content: "abcd") }   # 1 token
      let(:msg2) { double("msg", content: "abcdefgh") } # 2 tokens

      it "sums the estimated tokens for each element" do
        expect(described_class.estimate([msg1, msg2])).to eq(3)
      end

      it "returns 0 for an empty array" do
        expect(described_class.estimate([])).to eq(0)
      end
    end

    context "with a message-like object" do
      let(:msg) { double("msg", content: "hello world!") } # 12 chars -> ceil(12/4) = 3

      it "calls estimate on the content" do
        expect(described_class.estimate(msg)).to eq(3)
      end
    end

    context "with nil content" do
      let(:msg) { double("msg", content: nil) }

      it "treats nil content as empty string" do
        expect(described_class.estimate(msg)).to eq(0)
      end
    end
  end

  describe ".tokenizer=" do
    after { described_class.tokenizer = nil }

    it "uses the custom callable instead of the built-in heuristic" do
      described_class.tokenizer = ->(text) { text.split.length }
      expect(described_class.estimate("hello world")).to eq(2)
    end

    it "custom tokenizer receives the raw string" do
      received = nil
      described_class.tokenizer = ->(text) {
        received = text
        1
      }
      described_class.estimate("test input")
      expect(received).to eq("test input")
    end

    it "restoring to nil reverts to the built-in heuristic" do
      described_class.tokenizer = ->(text) { 999 }
      described_class.tokenizer = nil
      expect(described_class.estimate("abcd")).to eq(1)
    end

    it "custom tokenizer is applied when estimating an Array" do
      described_class.tokenizer = ->(text) { text.length }
      msg = double("msg", content: "hi")
      expect(described_class.estimate([msg])).to eq(2)
    end
  end
end
