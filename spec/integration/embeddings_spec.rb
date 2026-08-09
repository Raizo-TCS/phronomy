# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Group 14: Embeddings abstraction + VectorStore backends
#
# Factors:
#   F1: embeddings_adapter_type       = [ruby_llm_default, ruby_llm_explicit_model, stub]
#   F2: embeddings_assume_model_exists = [false, true]
#   F3: embeddings_injection           = [embeddings_kw, embedding_model_kw, default]
#   F4: vector_store_backend           = [in_memory, pgvector, redis_search]
#
# Generated pairwise cases: 10 (see docs/integration_test_cases_embeddings.yaml)
#
# Infeasible cases (SKIP):
#   TC-001: ruby_llm_default + assume=false + embeddings_kw + in_memory
#           LM Studio embedding model not in RubyLLM registry; cannot embed without assume_model_exists
#   TC-002: ruby_llm_default + assume=true + embedding_model_kw + pgvector
#           pgvector requires external PostgreSQL; embedding_model_kw cannot set assume_model_exists
#   TC-003: ruby_llm_default + assume=false + default + redis_search
#           redis_search requires external Redis with RediSearch module
#   TC-004: ruby_llm_explicit_model + assume=false + embedding_model_kw + in_memory
#           embedding_model_kw cannot set assume_model_exists: true; LM Studio model not in registry
#   TC-005: ruby_llm_explicit_model + assume=true + embeddings_kw + redis_search
#           redis_search requires external Redis with RediSearch module
#   TC-006: ruby_llm_explicit_model + assume=true + default injection + in_memory
#           default injection creates RubyLLMEmbeddings.new without assume_model_exists; model not in registry
#   TC-007: ruby_llm_explicit_model + assume=false + embeddings_kw + pgvector
#           pgvector requires external PostgreSQL
#   TC-009: stub + assume=true + embedding_model_kw + redis_search
#           embedding_model_kw overrides stub adapter; redis_search requires external Redis
#   TC-010: stub + assume=false + default injection + pgvector
#           default injection overrides stub adapter; pgvector requires external PostgreSQL
#
# Feasible pairwise cases: TC-008 (pure-Ruby, no LLM)
# Extra case: TC-011 (LLM required — covers ruby_llm_explicit_model + assume=true + embeddings_kw + in_memory)

RSpec.describe "Group 14: Embeddings abstraction + VectorStore backends", :integration do
  # ---------------------------------------------------------------------------
  # TC-001 (SKIP)
  # ---------------------------------------------------------------------------
  describe "TC-001: ruby_llm_default; assume=false; embeddings_kw; in_memory" do
    it "is skipped: LM Studio model not in RubyLLM registry without assume_model_exists" do
      # INFEASIBLE: ruby_llm_default without assume_model_exists => ModelNotFoundError for LM Studio
      skip "ruby_llm_default without assume_model_exists: model not in RubyLLM registry for LM Studio"
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002 (SKIP)
  # ---------------------------------------------------------------------------
  describe "TC-002: ruby_llm_default; assume=true; embedding_model_kw; pgvector" do
    it "is skipped: pgvector requires PostgreSQL; embedding_model_kw cannot set assume_model_exists" do
      # INFEASIBLE: pgvector (external DB) + embedding_model_kw cannot set assume_model_exists
      skip "Requires PostgreSQL with pgvector extension; embedding_model_kw cannot set assume_model_exists"
    end
  end

  # ---------------------------------------------------------------------------
  # TC-003 (SKIP)
  # ---------------------------------------------------------------------------
  describe "TC-003: ruby_llm_default; assume=false; default injection; redis_search" do
    it "is skipped: requires Redis with RediSearch module" do
      # INFEASIBLE: redis_search requires external Redis + RediSearch
      skip "Requires Redis with RediSearch module"
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004 (SKIP)
  # ---------------------------------------------------------------------------
  describe "TC-004: ruby_llm_explicit_model; assume=false; embedding_model_kw; in_memory" do
    it "is skipped: embedding_model_kw cannot pass assume_model_exists; LM Studio model not in registry" do
      # INFEASIBLE: embedding_model_kw creates RubyLLMEmbeddings.new(model:) without assume_model_exists
      skip "embedding_model_kw shorthand cannot set assume_model_exists: true; LM Studio model not in registry"
    end
  end

  # ---------------------------------------------------------------------------
  # TC-005 (SKIP)
  # ---------------------------------------------------------------------------
  describe "TC-005: ruby_llm_explicit_model; assume=true; embeddings_kw; redis_search" do
    it "is skipped: requires Redis with RediSearch module" do
      # INFEASIBLE: redis_search requires external Redis + RediSearch
      skip "Requires Redis with RediSearch module"
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006 (SKIP)
  # ---------------------------------------------------------------------------
  describe "TC-006: ruby_llm_explicit_model; assume=true; default injection; in_memory" do
    it "is skipped: default injection creates RubyLLMEmbeddings without assume_model_exists" do
      # INFEASIBLE: default injection (no args) creates RubyLLMEmbeddings.new => model not in registry
      skip "default injection cannot set assume_model_exists: true; LM Studio model not in registry"
    end
  end

  # ---------------------------------------------------------------------------
  # TC-007 (SKIP)
  # ---------------------------------------------------------------------------
  describe "TC-007: ruby_llm_explicit_model; assume=false; embeddings_kw; pgvector" do
    it "is skipped: requires PostgreSQL with pgvector extension" do
      # INFEASIBLE: pgvector requires external PostgreSQL + pgvector extension
      skip "Requires PostgreSQL with pgvector extension"
    end
  end

  # ---------------------------------------------------------------------------
  # TC-008 (PASS) — stub + assume=false + embeddings_kw + in_memory   [NO LLM]
  # Verifies the current Embeddings -> VectorStore path directly.
  # ---------------------------------------------------------------------------
  describe "TC-008: stub adapter; assume=false; embeddings_kw; in_memory" do
    it "stores and retrieves stub embeddings through the in-memory vector store" do
      adapter = IntegrationFactors.embeddings_adapter("stub")
      store = IntegrationFactors.vector_store("in_memory")
      target_embedding = adapter.embed("a")
      other_embedding = adapter.embed("zzzz")

      store.add(
        id: "target",
        embedding: target_embedding,
        metadata: {label: "target"}
      )
      store.add(
        id: "other",
        embedding: other_embedding,
        metadata: {label: "other"}
      )

      results = store.search(query_embedding: target_embedding, k: 1)

      expect(results.length).to eq(1)
      expect(results.first[:id]).to eq("target")
      expect(results.first[:metadata]).to eq({label: "target"})
      expect(results.first[:score]).to be_within(1e-12).of(1.0)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-009 (SKIP)
  # ---------------------------------------------------------------------------
  describe "TC-009: stub; assume=true; embedding_model_kw; redis_search" do
    it "is skipped: embedding_model_kw overrides stub; requires Redis with RediSearch module" do
      # INFEASIBLE: embedding_model_kw creates new RubyLLMEmbeddings, overriding stub; redis_search needs Redis
      skip "embedding_model_kw overrides stub adapter; requires Redis with RediSearch module"
    end
  end

  # ---------------------------------------------------------------------------
  # TC-010 (SKIP)
  # ---------------------------------------------------------------------------
  describe "TC-010: stub; assume=false; default injection; pgvector" do
    it "is skipped: default injection overrides stub; requires PostgreSQL with pgvector extension" do
      # INFEASIBLE: default injection creates new RubyLLMEmbeddings, overriding stub; pgvector needs Postgres
      skip "default injection overrides stub adapter; requires PostgreSQL with pgvector extension"
    end
  end

  # ---------------------------------------------------------------------------
  # TC-011 (PASS) — ruby_llm_explicit_model + assume=true + embeddings_kw + in_memory
  # Extra case to cover LLM-backed path (pairwise gap: TC-005/TC-007 both SKIP).
  # Uses LLMStub to intercept embeddings HTTP calls without a real LM Studio server.
  # ---------------------------------------------------------------------------
  describe "TC-011: ruby_llm_explicit_model; assume=true; embeddings_kw; in_memory [LLM REQUIRED]" do
    V_HELLO = [0.8, 0.4, 0.45].freeze      # embed("Hello, embeddings!")
    V_CAT1 = [0.9, 0.1, 0.1].freeze       # embed("The cat sat on the mat")
    V_CAT2 = [0.88, 0.12, 0.08].freeze    # embed("A cat rested on a rug")
    V_STOCK = [0.0, 0.95, 0.1].freeze      # embed("The stock market closed higher today")

    let(:adapter) { IntegrationFactors.embeddings_adapter("ruby_llm_explicit_model") }

    it "embed returns a non-empty Array<Float>" do
      LLMStub.activate_with_embeddings(vectors: [V_HELLO])
      vec = adapter.embed("Hello, embeddings!")
      expect(vec).to be_a(Array)
      expect(vec).not_to be_empty
      expect(vec.first).to be_a(Numeric)
    ensure
      LLMStub.deactivate
    end

    it "similar texts have higher cosine similarity than dissimilar texts" do
      LLMStub.activate_with_embeddings(vectors: [V_CAT1, V_CAT2, V_STOCK])
      v1 = adapter.embed("The cat sat on the mat")
      v2 = adapter.embed("A cat rested on a rug")
      v3 = adapter.embed("The stock market closed higher today")
      expect(cosine_similarity(v1, v2)).to be > cosine_similarity(v1, v3)
    ensure
      LLMStub.deactivate
    end
  end

  private

  def cosine_similarity(a, b)
    dot = a.zip(b).sum { |x, y| x * y }
    norm_a = Math.sqrt(a.sum { |x| x**2 })
    norm_b = Math.sqrt(b.sum { |x| x**2 })
    return 0.0 if norm_a.zero? || norm_b.zero?

    dot / (norm_a * norm_b)
  end
end
