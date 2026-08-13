# frozen_string_literal: true

RSpec.describe "VectorStore::AsyncBackend" do
  let(:pool) { Phronomy::Runtime.instance.offload }

  def make_sync_store
    Class.new(Phronomy::VectorStore::Base) do
      def add(id:, embedding:, metadata: {}, cancellation_token: nil)
        nil
      end

      def search(query_embedding:, k: 5, cancellation_token: nil)
        [{id: "doc1", score: 0.9, metadata: {}}]
      end

      def remove(id:)
        nil
      end

      def clear
        nil
      end

      def size
        1
      end
    end.new
  end

  describe "default async methods (OffloadPool delegation)" do
    let(:store) { make_sync_store }

    it "search_async returns a PendingOperation that resolves to search result" do
      op = store.search_async(query_embedding: [0.1, 0.2])
      expect(op).to respond_to(:blocking_wait)
      expect(op.wait_result).to eq([{id: "doc1", score: 0.9, metadata: {}}])
    end

    it "add_async returns a PendingOperation" do
      op = store.add_async(id: "x", embedding: [0.1, 0.2])
      expect(op).to respond_to(:blocking_wait)
      expect { op.wait_result }.not_to raise_error
    end

    it "remove_async returns a PendingOperation" do
      op = store.remove_async(id: "x")
      expect(op).to respond_to(:blocking_wait)
      expect { op.wait_result }.not_to raise_error
    end

    it "clear_async returns a PendingOperation" do
      op = store.clear_async
      expect(op).to respond_to(:blocking_wait)
      expect { op.wait_result }.not_to raise_error
    end
  end

  describe "native async override" do
    let(:native_store_class) do
      Class.new(Phronomy::VectorStore::Base) do
        include Phronomy::VectorStore::AsyncBackend

        attr_reader :native_search_called, :pool_submit_called

        def initialize
          super
          @native_search_called = false
          @pool_submit_called = false
        end

        def search_async(query_embedding:, k: 5, cancellation_token: nil, timeout: nil)
          @native_search_called = true
          Phronomy::Runtime.instance.offload.submit(on_full: :raise) do
            [{id: "native", score: 1.0, metadata: {}}]
          end
        end

        def search(query_embedding:, k: 5, cancellation_token: nil)
          @pool_submit_called = true
          [{id: "sync", score: 0.5, metadata: {}}]
        end
      end
    end

    let(:store) { native_store_class.new }

    it "calls the native override" do
      result = store.search_async(query_embedding: [0.1, 0.2]).wait_result
      expect(store.native_search_called).to be true
      expect(result).to eq([{id: "native", score: 1.0, metadata: {}}])
    end

    it "non-overridden async methods still fall back to OffloadPool" do
      op = store.add_async(id: "x", embedding: [0.1])
      expect(op).to respond_to(:blocking_wait)
      op.wait_result
    rescue NotImplementedError
      # Expected — Base#add is intentionally unimplemented in this test double.
    end
  end

  describe "Phronomy::VectorStore::Base" do
    it "includes AsyncBackend" do
      expect(Phronomy::VectorStore::Base.ancestors)
        .to include(Phronomy::VectorStore::AsyncBackend)
    end

    it "responds to all async operations" do
      store = make_sync_store
      expect(store).to respond_to(:search_async, :add_async, :remove_async, :clear_async)
    end
  end

  describe "InMemory compatibility" do
    let(:store) do
      instance = Phronomy::VectorStore::InMemory.new(dimension: 2)
      instance.add(id: "a", embedding: [1.0, 0.0], metadata: {text: "hello"})
      instance
    end

    it "search_async resolves through OffloadPool" do
      result = store.search_async(query_embedding: [1.0, 0.0], k: 1).wait_result
      expect(result.first[:id]).to eq("a")
    end
  end
end
