# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "LLMChain integration", :integration do
  let(:chain) { Phronomy::Chain::LLMChain.new }

  describe "#invoke with a String input" do
    it "returns a non-empty String response from LM Studio" do
      result = chain.invoke("Reply with only the word: PONG")
      expect(result).to be_a(String)
      expect(result).not_to be_empty
    end
  end

  describe "#invoke with a Hash input (user key)" do
    it "sends the user message and returns a String response" do
      result = chain.invoke({ user: "Reply with only the word: PONG" })
      expect(result).to be_a(String)
      expect(result).not_to be_empty
    end
  end

  describe "#invoke with a Hash input (system + user keys)" do
    it "applies the system prompt and returns a response" do
      result = chain.invoke({
        system: "You are a test assistant. Always reply in uppercase.",
        user: "say hello"
      })
      expect(result).to be_a(String)
      expect(result).not_to be_empty
    end
  end

  describe "#stream" do
    it "yields at least one chunk and returns the full response" do
      chunks = []
      result = chain.stream("Reply with only the word: PONG") { |chunk| chunks << chunk }
      expect(chunks).not_to be_empty
      expect(result).to be_a(String)
      expect(result).not_to be_empty
    end
  end
end
