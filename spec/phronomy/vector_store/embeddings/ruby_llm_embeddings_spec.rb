# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::VectorStore::Embeddings::RubyLLMEmbeddings do
  let(:vector) { [0.1, 0.2, 0.3] }

  # Minimal stand-in for the RubyLLM::EmbeddingResponse duck-type.
  let(:stub_response) { instance_double("RubyLLM::EmbeddingResponse", vectors: vector) }

  # Contract tests: verify RubyLLMEmbeddings satisfies the embeddings adapter interface (Issue #212).
  it_behaves_like "an embeddings adapter" do
    let(:stub_response_inner) { instance_double("RubyLLM::EmbeddingResponse", vectors: [0.1, 0.2, 0.3]) }

    before { allow(RubyLLM).to receive(:embed).and_return(stub_response_inner) }

    let(:adapter) { described_class.new }
  end

  describe "#embed" do
    context "with no model or provider specified" do
      subject(:adapter) { described_class.new }

      it "calls RubyLLM.embed with no extra options and returns vectors" do
        expect(RubyLLM).to receive(:embed).with("hello").and_return(stub_response)
        result = adapter.embed("hello")
        expect(result).to eq(vector)
      end
    end

    context "with model specified" do
      subject(:adapter) { described_class.new(model: "text-embedding-3-small") }

      it "passes model: to RubyLLM.embed" do
        expect(RubyLLM).to receive(:embed).with("hi", model: "text-embedding-3-small").and_return(stub_response)
        result = adapter.embed("hi")
        expect(result).to eq(vector)
      end
    end

    context "with provider specified" do
      subject(:adapter) { described_class.new(provider: :openai) }

      it "passes provider: to RubyLLM.embed" do
        expect(RubyLLM).to receive(:embed).with("hi", provider: :openai).and_return(stub_response)
        result = adapter.embed("hi")
        expect(result).to eq(vector)
      end
    end

    context "with both model and provider specified" do
      subject(:adapter) { described_class.new(model: "text-embedding-3-small", provider: :openai) }

      it "passes both options to RubyLLM.embed" do
        expect(RubyLLM).to receive(:embed)
          .with("test", model: "text-embedding-3-small", provider: :openai)
          .and_return(stub_response)
        result = adapter.embed("test")
        expect(result).to eq(vector)
      end
    end

    context "with assume_model_exists: true" do
      subject(:adapter) { described_class.new(model: "local-embed-model", assume_model_exists: true) }

      it "passes assume_model_exists: true to RubyLLM.embed" do
        expect(RubyLLM).to receive(:embed)
          .with("hi", model: "local-embed-model", assume_model_exists: true)
          .and_return(stub_response)
        result = adapter.embed("hi")
        expect(result).to eq(vector)
      end
    end
  end

  describe "inheritance" do
    it "inherits from Phronomy::VectorStore::Embeddings::Base" do
      expect(described_class.ancestors).to include(Phronomy::VectorStore::Embeddings::Base)
    end
  end
end
