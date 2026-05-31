# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::RAG::Embeddings::Base do
  subject(:adapter) { described_class.new }

  describe "#embed" do
    it "raises NotImplementedError" do
      expect { adapter.embed("hello") }.to raise_error(NotImplementedError, /embed/)
    end

    it "raises CancellationError immediately when a cancelled token is passed (#242)" do
      token = Phronomy::Concurrency::CancellationToken.new
      token.cancel!
      expect { adapter.embed("hello", token) }.to raise_error(Phronomy::CancellationError)
    end
  end

  describe "Embeddings::Base#embed_async" do
    it "delegates to embed via BlockingAdapterPool" do
      emb = Class.new(Phronomy::RAG::Embeddings::Base) do
        def embed(text, _cancellation_token = nil)
          [0.1, 0.2, 0.3]
        end
      end.new

      op = emb.embed_async("hello")
      result = op.await
      expect(result).to eq([0.1, 0.2, 0.3])
    end
  end
end
