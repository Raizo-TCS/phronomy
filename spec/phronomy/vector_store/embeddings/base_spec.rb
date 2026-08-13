# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::VectorStore::Embeddings::Base do
  subject(:adapter) { described_class.new }

  describe "#embed" do
    it "raises NotImplementedError" do
      expect { adapter.embed("hello") }.to raise_error(NotImplementedError, /embed/)
    end

    it "raises CancellationError immediately when a cancelled token is passed" do
      token = Phronomy::Concurrency::CancellationToken.new
      token.cancel!
      expect { adapter.embed("hello", token) }.to raise_error(Phronomy::CancellationError)
    end
  end

  describe "#embed_async" do
    it "delegates synchronous embed work through OffloadPool" do
      embeddings = Class.new(Phronomy::VectorStore::Embeddings::Base) do
        def embed(_text, _cancellation_token = nil)
          [0.1, 0.2, 0.3]
        end
      end.new

      expect(embeddings.embed_async("hello").wait_result).to eq([0.1, 0.2, 0.3])
    end
  end
end
