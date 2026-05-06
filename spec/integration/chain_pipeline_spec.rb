# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "Chain pipeline integration", :integration do
  describe "PromptTemplate >> LLMChain" do
    let(:chain) do
      prompt = Phronomy::Chain::PromptTemplate.new(
        template: "What is the capital of <%= country %>? Reply with only the city name."
      )
      llm = Phronomy::Chain::LLMChain.new
      prompt >> llm
    end

    it "expands the template and returns a response from LM Studio" do
      result = chain.invoke({country: "France"})
      expect(result).to be_a(String)
      expect(result).not_to be_empty
      expect(result.downcase).to include("paris")
    end
  end

  describe "PromptTemplate >> LLMChain >> OutputParser" do
    let(:chain) do
      prompt = Phronomy::Chain::PromptTemplate.new(
        template: 'Return ONLY valid JSON with two keys: "number" (integer 42) and "word" (string "hello"). No explanation.'
      )
      llm = Phronomy::Chain::LLMChain.new
      parser = Phronomy::OutputParser::JsonParser.new
      prompt >> llm >> parser
    end

    it "parses the JSON response into a Hash" do
      result = chain.invoke({})
      expect(result).to be_a(Hash)
      expect(result[:number]).to eq(42)
      expect(result[:word]).to eq("hello")
    end
  end
end
