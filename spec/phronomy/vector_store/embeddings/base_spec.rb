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

  it "does not expose asynchronous execution on the synchronous SPI" do
    expect(adapter).not_to respond_to(:embed_async)
  end
end
