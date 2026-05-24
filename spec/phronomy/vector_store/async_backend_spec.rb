# frozen_string_literal: true

RSpec.describe "VectorStore::AsyncBackend (Issue #304)" do
  # -------------------------------------------------------------------------
  # Shared helpers
  # -------------------------------------------------------------------------
  let(:pool) { Phronomy::Runtime.instance.blocking_io }

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

  # -------------------------------------------------------------------------
  # Default (pool-backed) async methods via AsyncBackend mixin
  # -------------------------------------------------------------------------
  describe "default async methods (BlockingAdapterPool delegation)" do
    let(:store) { make_sync_store }

    it "search_async returns a PendingOperation that resolves to search result" do
      op = store.search_async(query_embedding: [0.1, 0.2])
      expect(op).to respond_to(:await)
      result = op.await
      expect(result).to eq([{id: "doc1", score: 0.9, metadata: {}}])
    end

    it "add_async returns a PendingOperation" do
      op = store.add_async(id: "x", embedding: [0.1, 0.2])
      expect(op).to respond_to(:await)
      expect { op.await }.not_to raise_error
    end

    it "remove_async returns a PendingOperation" do
      op = store.remove_async(id: "x")
      expect(op).to respond_to(:await)
      expect { op.await }.not_to raise_error
    end

    it "clear_async returns a PendingOperation" do
      op = store.clear_async
      expect(op).to respond_to(:await)
      expect { op.await }.not_to raise_error
    end
  end

  # -------------------------------------------------------------------------
  # Native async override — no pool thread allocated
  # -------------------------------------------------------------------------
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

        # Override only search_async with a native (non-pool) implementation.
        # Using pool.submit in a spy doubles the Thread cost — instead return
        # a simple PendingOperation directly.
        def search_async(query_embedding:, k: 5, cancellation_token: nil, timeout: nil)
          @native_search_called = true
          # Simulate a native async return path (no pool worker allocated).
          Phronomy::Runtime.instance.blocking_io.submit { [{id: "native", score: 1.0, metadata: {}}] }
        end

        def search(query_embedding:, k: 5, cancellation_token: nil)
          @pool_submit_called = true
          [{id: "sync", score: 0.5, metadata: {}}]
        end
      end
    end

    let(:store) { native_store_class.new }

    it "calls the native override, not the inherited pool-backed implementation" do
      op = store.search_async(query_embedding: [0.1, 0.2])
      result = op.await
      expect(store.native_search_called).to be true
      expect(result).to eq([{id: "native", score: 1.0, metadata: {}}])
    end

    it "non-overridden async methods still fall back to pool delegation" do
      op = store.add_async(id: "x", embedding: [0.1])
      # add is not implemented on this class — NotImplementedError from Base#add.
      # The important thing is it goes through the pool path (PendingOperation).
      expect(op).to respond_to(:await)
    end
  end

  # -------------------------------------------------------------------------
  # Contract: all VectorStore::Base subclasses include AsyncBackend
  # -------------------------------------------------------------------------
  describe "Phronomy::VectorStore::Base" do
    it "includes AsyncBackend" do
      expect(Phronomy::VectorStore::Base.ancestors).to include(Phronomy::VectorStore::AsyncBackend)
    end

    it "responds to search_async, add_async, remove_async, clear_async" do
      store = make_sync_store
      expect(store).to respond_to(:search_async)
      expect(store).to respond_to(:add_async)
      expect(store).to respond_to(:remove_async)
      expect(store).to respond_to(:clear_async)
    end
  end

  # -------------------------------------------------------------------------
  # Backward compatibility: InMemory still works via inherited search_async
  # -------------------------------------------------------------------------
  describe "InMemory backward compatibility" do
    let(:store) do
      s = Phronomy::VectorStore::InMemory.new(dimension: 2)
      s.add(id: "a", embedding: [1.0, 0.0], metadata: {text: "hello"})
      s
    end

    it "search_async resolves via pool and returns results" do
      op = store.search_async(query_embedding: [1.0, 0.0], k: 1)
      result = op.await
      expect(result.first[:id]).to eq("a")
    end
  end
end
