# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::VectorStore::Embeddings::AsyncClient do
  let(:sync_backend) do
    Class.new(Phronomy::VectorStore::Embeddings::Base) do
      def embed(text, cancellation_token = nil)
        []
      end
    end.new
  end
  let(:sync_operation) { :embed }

  def build_client(pool: nil)
    described_class.new(adapter: sync_backend, pool: pool)
  end

  def invoke_async(instance, token: nil, timeout: nil)
    instance.embed_async("query", token, timeout: timeout)
  end

  it_behaves_like "an asynchronous backend client"

  it "preserves the positional cancellation argument, text identity and result identity" do
    text = +"query"
    token = Phronomy::Concurrency::CancellationToken.new
    vector = [1.0, 2.0]
    expect(sync_backend).to receive(:embed) do |actual_text, actual_token|
      expect(actual_text).to equal(text)
      expect(actual_token).to equal(token)
      vector
    end
    task = build_client.embed_async(text, token)
    expect(task.wait_result(timeout: 2)).to equal(vector)
  end
end
