# frozen_string_literal: true

require "spec_helper"

RSpec.describe "VectorStore async convenience" do
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

  describe "OffloadPool delegation" do
    let(:store) { make_sync_store }

    it "search_async returns a Task that resolves to the search result" do
      task = store.search_async(query_embedding: [0.1, 0.2])

      expect(task).to be_a(Phronomy::Task)
      expect(task.wait_result).to eq([{id: "doc1", score: 0.9, metadata: {}}])
    end

    it "add_async returns a Task" do
      task = store.add_async(id: "x", embedding: [0.1, 0.2])

      expect(task).to be_a(Phronomy::Task)
      expect { task.wait_result }.not_to raise_error
    end

    it "remove_async returns a Task" do
      task = store.remove_async(id: "x")

      expect(task).to be_a(Phronomy::Task)
      expect { task.wait_result }.not_to raise_error
    end

    it "clear_async returns a Task" do
      task = store.clear_async

      expect(task).to be_a(Phronomy::Task)
      expect { task.wait_result }.not_to raise_error
    end

    it "executes the synchronous backend method on an OffloadPool worker" do
      caller_thread = Thread.current
      backend_thread = nil
      store = Class.new(Phronomy::VectorStore::Base) do
        define_method(:search) do |query_embedding:, k: 5, cancellation_token: nil|
          backend_thread = Thread.current
          []
        end
      end.new

      store.search_async(query_embedding: [0.1]).wait_result

      expect(backend_thread).not_to be(caller_thread)
      expect(backend_thread.name).to include("phronomy-offload-pool")
    end
  end

  describe "Phronomy::VectorStore::Base" do
    it "provides all async convenience operations" do
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

    it "search_async resolves through OffloadPool as a Task" do
      task = store.search_async(query_embedding: [1.0, 0.0], k: 1)

      expect(task).to be_a(Phronomy::Task)
      result = task.wait_result
      expect(result.first[:id]).to eq("a")
    end
  end
end
