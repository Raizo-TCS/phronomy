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

RSpec.describe "RAG parallel multi-source fetch (Issue #303)" do
  let(:agent_class) { Class.new(Phronomy::Agent::Base) { model "test-model" } }
  let(:agent) { agent_class.new }

  def make_ks(chunks, delay: 0)
    Class.new(Phronomy::KnowledgeSource::Base) do
      define_method(:fetch) do |query: nil, cancellation_token: nil|
        sleep delay if delay > 0
        chunks
      end
    end.new
  end

  it "returns chunks from all sources in registration order" do
    ks1 = make_ks([{content: "from-1", type: "text", source: "s1"}])
    ks2 = make_ks([{content: "from-2", type: "text", source: "s2"}])

    ctx = agent.send(:build_context, "query", config: {knowledge_sources: [ks1, ks2]})
    ctx_str = ctx[:system].to_s
    expect(ctx_str).to include("from-1")
    expect(ctx_str).to include("from-2")
  end

  it "fetches multiple sources concurrently (wall time < sum of individual delays)" do
    delay = 0.1
    ks1 = make_ks([{content: "a", type: "text", source: "s1"}], delay: delay)
    ks2 = make_ks([{content: "b", type: "text", source: "s2"}], delay: delay)
    ks3 = make_ks([{content: "c", type: "text", source: "s3"}], delay: delay)

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    agent.send(:build_context, "query", config: {knowledge_sources: [ks1, ks2, ks3]})
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    # Sequential would take ~0.3s; parallel should finish well under 0.25s.
    expect(elapsed).to be < 0.25
  end

  it "skips a failed source by default (rag_failure_policy: :skip)" do
    bad_ks = Class.new(Phronomy::KnowledgeSource::Base) do
      def fetch(query: nil, cancellation_token: nil)
        raise Phronomy::Error, "source exploded"
      end
    end.new
    good_ks = make_ks([{content: "good", type: "text", source: "ok"}])

    expect {
      ctx = agent.send(:build_context, "query", config: {knowledge_sources: [bad_ks, good_ks]})
      expect(ctx[:system].to_s).to include("good")
    }.not_to raise_error
  end

  it "raises when rag_failure_policy: :fail and a source fails" do
    bad_ks = Class.new(Phronomy::KnowledgeSource::Base) do
      def fetch(query: nil, cancellation_token: nil)
        raise Phronomy::Error, "source exploded"
      end
    end.new

    expect {
      agent.send(:build_context, "query",
        config: {knowledge_sources: [bad_ks], rag_failure_policy: :fail})
    }.to raise_error(Phronomy::Error, "source exploded")
  end

  it "returns empty context when no knowledge sources are given" do
    expect {
      agent.send(:build_context, "query", config: {})
    }.not_to raise_error
  end
end

RSpec.describe "RAG gate enforcement (Issue #319)" do
  let(:agent_class) { Class.new(Phronomy::Agent::Base) { model "test-model" } }
  let(:agent) { agent_class.new }

  around do |example|
    # Limit the RAG gate to 1 concurrent fetch, reset afterwards.
    original = Phronomy.configuration.max_concurrent_rag_fetches
    Phronomy.configuration.max_concurrent_rag_fetches = 1
    Phronomy::Runtime.instance.reset_gate(:rag)
    example.run
  ensure
    Phronomy.configuration.max_concurrent_rag_fetches = original
    Phronomy::Runtime.instance.reset_gate(:rag)
  end

  it "honours max_concurrent_rag_fetches by serialising fetches when cap is 1" do
    # Each fetch sleeps briefly so we can measure concurrency.
    concurrency = 0
    max_seen = 0
    mutex = Mutex.new

    make_ks = lambda do
      Class.new(Phronomy::KnowledgeSource::Base) do
        define_method(:fetch) do |query: nil, cancellation_token: nil|
          mutex.synchronize do
            concurrency += 1
            max_seen = concurrency if concurrency > max_seen
          end
          sleep 0.02
          mutex.synchronize { concurrency -= 1 }
          [{content: "data", type: "text", source: "s"}]
        end
      end.new
    end

    agent.send(:build_context, "q",
      config: {knowledge_sources: [make_ks.call, make_ks.call, make_ks.call]})

    # With a gate cap of 1, no more than 1 fetch should run simultaneously.
    expect(max_seen).to eq(1)
  end

  it "tracks gate acquisition during fetch (Issue #319 gate is connected)" do
    gate = Phronomy::Runtime.instance.gate(:rag)
    observed = []

    ks = Class.new(Phronomy::KnowledgeSource::Base) do
      define_method(:fetch) do |query: nil, cancellation_token: nil|
        observed << gate.current_count
        [{content: "x", type: "text", source: "g"}]
      end
    end.new

    agent.send(:build_context, "q", config: {knowledge_sources: [ks]})

    # The gate should have been acquired (count == 1) during the fetch.
    expect(observed).to eq([1])
  end
end
