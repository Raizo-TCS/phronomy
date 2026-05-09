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
  # Verifies the full Retrieval::Semantic workflow with a stub adapter and InMemory store.
  # ---------------------------------------------------------------------------
  describe "TC-008: stub adapter; assume=false; embeddings_kw; in_memory" do
    let(:adapter) { IntegrationFactors.embeddings_adapter("stub") }
    let(:store) { IntegrationFactors.vector_store("in_memory") }
    let(:memory) do
      Phronomy::Memory::ConversationManager.new(
        storage: Phronomy::Memory::Storage::InMemory.new,
        retrieval: Phronomy::Memory::Retrieval::Semantic.new(embeddings: adapter, store: store, k: 3)
      )
    end

    it "save and load with query return the semantically closest message" do
      msg_a = make_message("aaaa")
      msg_b = make_message("xyz")
      memory.save(thread_id: "t1", messages: [msg_a, msg_b])

      results = memory.load(thread_id: "t1", query: "aaaa")
      expect(results).not_to be_empty
      expect(results.first.content.to_s).to eq("aaaa")
    end

    it "load without query returns k most recent messages" do
      msgs = (1..5).map { |i| make_message("msg #{i}") }
      memory.save(thread_id: "t2", messages: msgs)

      results = memory.load(thread_id: "t2")
      expect(results.size).to eq(3)
      expect(results.last.content.to_s).to eq("msg 5")
    end

    it "clear removes messages for the given thread and keeps other threads intact" do
      mem_t3 = Phronomy::Memory::ConversationManager.new(
        storage: Phronomy::Memory::Storage::InMemory.new,
        retrieval: Phronomy::Memory::Retrieval::Semantic.new(embeddings: adapter, k: 3)
      )
      mem_t4 = Phronomy::Memory::ConversationManager.new(
        storage: Phronomy::Memory::Storage::InMemory.new,
        retrieval: Phronomy::Memory::Retrieval::Semantic.new(embeddings: adapter, k: 3)
      )
      mem_t3.save(thread_id: "t3", messages: [make_message("thread-a message")])
      mem_t4.save(thread_id: "t4", messages: [make_message("thread-b message")])
      mem_t3.clear(thread_id: "t3")

      expect(mem_t3.load(thread_id: "t3")).to be_empty
      expect(mem_t4.load(thread_id: "t4")).not_to be_empty
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
    # Vectors chosen so that:
    #   v_cat and v_feline are similar (high dot product),
    #   v_cat and v_stock are dissimilar (low dot product).
    V_HELLO = [0.8, 0.4, 0.45].freeze      # embed("Hello, embeddings!")
    V_CAT1 = [0.9, 0.1, 0.1].freeze       # embed("The cat sat on the mat")
    V_CAT2 = [0.88, 0.12, 0.08].freeze    # embed("A cat rested on a rug")
    V_STOCK = [0.0, 0.95, 0.1].freeze      # embed("The stock market closed higher today")
    V_CAT3 = [0.85, 0.1, 0.05].freeze     # embed("The cat climbed the tree")
    V_STOCK2 = [0.05, 0.9, 0.1].freeze      # embed("Stock prices rose sharply")
    V_FELINE = [0.87, 0.1, 0.09].freeze     # embed("feline climbing")

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

    it "Retrieval::Semantic retrieves the semantically relevant message via semantic search" do
      LLMStub.activate_with_embeddings(vectors: [V_CAT3, V_STOCK2, V_FELINE])
      memory = Phronomy::Memory::ConversationManager.new(
        storage: Phronomy::Memory::Storage::InMemory.new,
        retrieval: Phronomy::Memory::Retrieval::Semantic.new(embeddings: adapter, k: 5)
      )
      msg_cat = make_message("The cat climbed the tree")
      msg_stock = make_message("Stock prices rose sharply")
      memory.save(thread_id: "t5", messages: [msg_cat, msg_stock])

      results = memory.load(thread_id: "t5", query: "feline climbing")
      expect(results).not_to be_empty
      expect(results.map { |m| m.content.to_s }).to include("The cat climbed the tree")
    ensure
      LLMStub.deactivate
    end
  end

  private

  def make_message(content)
    RubyLLM::Message.new(role: :user, content: content)
  end

  def cosine_similarity(a, b)
    dot = a.zip(b).sum { |x, y| x * y }
    norm_a = Math.sqrt(a.sum { |x| x**2 })
    norm_b = Math.sqrt(b.sum { |x| x**2 })
    return 0.0 if norm_a.zero? || norm_b.zero?

    dot / (norm_a * norm_b)
  end
end
