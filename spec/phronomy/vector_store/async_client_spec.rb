# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::VectorStore::AsyncClient do
  let(:sync_backend) do
    Class.new(Phronomy::VectorStore::Base) do
      def search(query_embedding:, k: 5, cancellation_token: nil)
        []
      end
    end.new
  end
  let(:sync_operation) { :search }

  def build_client(pool: nil)
    described_class.new(backend: sync_backend, pool: pool)
  end

  def invoke_async(instance, token: nil, timeout: nil)
    instance.search_async(query_embedding: [1.0], cancellation_token: token, timeout: timeout)
  end

  it_behaves_like "an asynchronous backend client"

  describe "synchronous operation forwarding" do
    let(:pool) { Phronomy::Concurrency::OffloadPool.new(pool_size: 1, queue_size: 2) }
    let(:client) { build_client(pool: pool) }
    let(:token) { Phronomy::Concurrency::CancellationToken.new }
    after { pool.shutdown(drain_timeout: 2) }

    it "forwards the original vector, metadata and cancellation signal to add" do
      embedding = [1.0, 2.0]
      metadata = {content: "document"}
      received = Queue.new
      allow(sync_backend).to receive(:add) do |id:, embedding:, metadata:, cancellation_token:|
        received << [id, embedding, metadata, cancellation_token]
        sync_backend
      end
      result = client.add_async(id: "doc", embedding: embedding, metadata: metadata, cancellation_token: token).wait_result(timeout: 2)
      expect(result).to equal(sync_backend)
      args = received.pop
      expect(args.first).to eq("doc")
      expect(args[1]).to equal(embedding)
      expect(args[2]).to equal(metadata)
      expect(args[3]).to equal(token)
    end

    it "preserves default metadata and k and passes no extra synchronous keywords" do
      expect(sync_backend).to receive(:add).with(id: "doc", embedding: [1.0], metadata: {}, cancellation_token: nil)
      expect(sync_backend).to receive(:search).with(query_embedding: [1.0], k: 5, cancellation_token: nil).and_return([])
      client.add_async(id: "doc", embedding: [1.0]).wait_result(timeout: 2)
      expect(client.search_async(query_embedding: [1.0]).wait_result(timeout: 2)).to eq([])
    end

    it "preserves the search result and exact query and token" do
      query = [0.0, 1.0]
      results = [{id: "match", score: 1.0, metadata: {}}]
      expect(sync_backend).to receive(:search) do |query_embedding:, k:, cancellation_token:|
        expect(query_embedding).to equal(query)
        expect(k).to eq(2)
        expect(cancellation_token).to equal(token)
        results
      end
      task = client.search_async(query_embedding: query, k: 2, cancellation_token: token)
      expect(task.wait_result(timeout: 2)).to equal(results)
    end

    it "keeps cancellation on the submitted remove and clear without passing it to the synchronous SPI" do
      expect(pool).to receive(:submit).twice.with(timeout: nil, cancellation_token: token, on_full: :raise).and_call_original
      expect(sync_backend).to receive(:remove).with(id: "doc").and_return(:removed)
      expect(sync_backend).to receive(:clear).with(no_args).and_return(:cleared)
      expect(client.remove_async(id: "doc", cancellation_token: token).wait_result(timeout: 2)).to eq(:removed)
      expect(client.clear_async(cancellation_token: token).wait_result(timeout: 2)).to eq(:cleared)
    end

    it "works with the unchanged InMemory synchronous backend" do
      store = Phronomy::VectorStore::InMemory.new(dimension: 2)
      instance = described_class.new(backend: store, pool: pool)
      instance.add_async(id: "a", embedding: [1.0, 0.0], metadata: {text: "hello"}).wait_result(timeout: 2)
      expect(instance.search_async(query_embedding: [1.0, 0.0], k: 1).wait_result(timeout: 2).first[:id]).to eq("a")
      instance.remove_async(id: "a").wait_result(timeout: 2)
      expect(store.size).to eq(0)
      instance.clear_async.wait_result(timeout: 2)
    end
  end
end
