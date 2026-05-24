# frozen_string_literal: true

RSpec.describe "RAG async boundary (Issue #267)" do
  let(:agent_class) { Class.new(Phronomy::Agent::Base) { model "test-model" } }
  let(:agent) { agent_class.new }
  let(:pool) { Phronomy::Runtime.instance.blocking_io }

  describe "KnowledgeSource#fetch_async" do
    it "delegates to fetch via BlockingAdapterPool" do
      ks = Class.new(Phronomy::KnowledgeSource::Base) do
        def fetch(query: nil, cancellation_token: nil)
          [{content: "result", type: "text", source: "test"}]
        end
      end.new

      op = ks.fetch_async(query: "hello")
      result = op.await
      expect(result).to eq([{content: "result", type: "text", source: "test"}])
    end
  end

  describe "Embeddings::Base#embed_async" do
    it "delegates to embed via BlockingAdapterPool" do
      emb = Class.new(Phronomy::Embeddings::Base) do
        def embed(text, _cancellation_token = nil)
          [0.1, 0.2, 0.3]
        end
      end.new

      op = emb.embed_async("hello")
      result = op.await
      expect(result).to eq([0.1, 0.2, 0.3])
    end
  end

  describe "VectorStore::Base#search_async" do
    it "delegates to search via BlockingAdapterPool" do
      vs = Class.new(Phronomy::VectorStore::Base) do
        def search(query_embedding:, k: 5, cancellation_token: nil)
          [{content: "found", score: 0.9}]
        end
      end.new

      op = vs.search_async(query_embedding: [0.1, 0.2, 0.3])
      result = op.await
      expect(result).to eq([{content: "found", score: 0.9}])
    end
  end

  describe "Agent#build_context uses fetch_async" do
    it "calls fetch_async on each knowledge source" do
      ks = double("KnowledgeSource")
      pending_op = pool.submit { [{content: "ctx", type: "text", source: "src"}] }
      expect(ks).to receive(:fetch_async).with(
        query: "hello",
        cancellation_token: nil,
        timeout: nil
      ).and_return(pending_op)

      agent.send(:build_context, "hello",
        messages: [],
        thread_id: nil,
        config: {knowledge_sources: [ks]})
    end
  end
end
