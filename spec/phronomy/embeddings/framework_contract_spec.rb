# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Embeddings framework contract" do
  let(:adapter) do
    Class.new(Phronomy::Embeddings::Base) do
      protected

      def perform_embed(text, token = nil) = [1, 2.5]
    end.new
  end

  it "owns validation and numeric normalization outside the provider" do
    expect(adapter.embed("text")).to eq([1.0, 2.5])
    expect(adapter.method(:embed).owner).to eq(Phronomy::Embeddings::Base)
    expect(adapter).not_to respond_to(:perform_embed)
    expect(adapter).not_to receive(:perform_embed)
    expect { adapter.embed(nil) }.to raise_error(ArgumentError)
  end

  [nil, [], [[1.0]], ["0.5"], [Float::NAN], [Float::INFINITY], [Complex(1, 2)]].each do |result|
    it "rejects malformed provider output #{result.inspect}" do
      allow(adapter).to receive(:perform_embed).and_return(result)
      expect { adapter.embed("text") }.to raise_error(Phronomy::Embeddings::InvalidResultError)
    end
  end

  it "forwards the structural cancellation signal and preserves application failure identity" do
    signal = double(raise_if_cancelled!: nil)
    error = ArgumentError.new("application failed")
    expect(adapter).to receive(:perform_embed).with("text", signal).once.and_raise(error)
    expect { adapter.embed("text", signal) }.to raise_error { |actual| expect(actual).to equal(error) }
  end

  it "translates SDK provider errors while preserving the original cause" do
    adapter = Phronomy::Embeddings::RubyLLMEmbeddings.new
    error = RubyLLM::Error.new("provider failed")
    expect(RubyLLM).to receive(:embed).once.and_raise(error)
    expect { adapter.embed("text") }.to raise_error(Phronomy::Embeddings::TransportError) { |actual|
      expect(actual.cause).to equal(error)
    }
  end

  it "removes the old embedding and document namespaces without aliases" do
    expect(Phronomy::VectorStore.const_defined?(:Embeddings, false)).to be(false)
    expect(Phronomy::VectorStore.const_defined?(:Loader, false)).to be(false)
    expect(Phronomy::VectorStore.const_defined?(:Splitter, false)).to be(false)
    expect(Phronomy::Documents::Loader::Base.name).to eq("Phronomy::Documents::Loader::Base")
    expect(Phronomy::Documents::Splitter::Base.name).to eq("Phronomy::Documents::Splitter::Base")
  end
end
