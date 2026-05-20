# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"

# Group 35: VectorStore Dimension Validation
# Pairwise factors: vs_dimension_init × vs_operation_type × vs_size_match
# Generated stubs: 6 cases
#
# Infeasible cases:
#   TC-006 (inferred / search_before_add / mismatch):
#     When dimension is inferred (nil initially) and #search is called before
#     any #add, @expected_dimension is nil so validate_embedding_dimension! is
#     a no-op.  The "mismatch" factor has no observable effect — no ArgumentError
#     can be raised.  This combination is structurally infeasible.
#
# LLM required: None — all tests exercise pure-Ruby InMemory vector store logic.

RSpec.describe "Group 35: VectorStore Dimension Validation", :integration do
  # ---------------------------------------------------------------------------
  # TC-001: explicit / add / match
  #
  # Store constructed with dimension: 2.  #add called with a 2-element embedding.
  # Expected: succeeds; document is stored.
  # ---------------------------------------------------------------------------
  describe "TC-001: explicit / add / match" do
    it "stores the document without raising" do
      store = IntegrationFactors.vs_store("explicit")
      emb = IntegrationFactors.vs_embedding("match")
      expect { store.add(id: "doc1", embedding: emb, metadata: {text: "hello"}) }
        .not_to raise_error
      expect(store.size).to eq(1)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: explicit / search / mismatch
  #
  # Store constructed with dimension: 2.  #search called with a 3-element
  # embedding (mismatch).
  # Expected: ArgumentError with dimension mismatch message.
  # ---------------------------------------------------------------------------
  describe "TC-002: explicit / search / mismatch" do
    it "raises ArgumentError when query embedding has wrong dimension" do
      store = IntegrationFactors.vs_store("explicit")
      store.add(id: "seed", embedding: [0.6, 0.8], metadata: {})
      bad_emb = IntegrationFactors.vs_embedding("mismatch")
      expect { store.search(query_embedding: bad_emb, k: 1) }
        .to raise_error(ArgumentError, /dimension mismatch.*expected 2.*got 3/i)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-003: explicit / search_before_add / match
  #
  # Store constructed with dimension: 2.  #search called before any #add,
  # with a 2-element embedding (match).
  # Expected: returns [] (no documents); no error.
  # ---------------------------------------------------------------------------
  describe "TC-003: explicit / search_before_add / match" do
    it "returns empty results without raising when no documents have been added" do
      store = IntegrationFactors.vs_store("explicit")
      emb = IntegrationFactors.vs_embedding("match")
      result = nil
      expect { result = store.search(query_embedding: emb, k: 3) }.not_to raise_error
      expect(result).to eq([])
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004: inferred / add / mismatch
  #
  # Store constructed without explicit dimension.  First #add establishes
  # dimension = 2.  Second #add called with a 3-element embedding (mismatch).
  # Expected: first add succeeds; second add raises ArgumentError.
  # ---------------------------------------------------------------------------
  describe "TC-004: inferred / add / mismatch" do
    it "raises ArgumentError on the second add after dimension is inferred" do
      store = IntegrationFactors.vs_store("inferred")
      store.add(id: "doc1", embedding: [0.6, 0.8], metadata: {text: "first"})
      bad_emb = IntegrationFactors.vs_embedding("mismatch")
      expect { store.add(id: "doc2", embedding: bad_emb, metadata: {}) }
        .to raise_error(ArgumentError, /dimension mismatch.*expected 2.*got 3/i)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-005: inferred / search / match
  #
  # Store constructed without explicit dimension.  One document added (dimension
  # inferred as 2).  #search called with a 2-element query embedding.
  # Expected: returns the added document as the top result.
  # ---------------------------------------------------------------------------
  describe "TC-005: inferred / search / match" do
    it "returns results when query embedding matches inferred dimension" do
      store = IntegrationFactors.vs_store("inferred")
      store.add(id: "doc1", embedding: [1.0, 0.0], metadata: {label: "A"})
      store.add(id: "doc2", embedding: [0.0, 1.0], metadata: {label: "B"})

      results = store.search(query_embedding: [1.0, 0.0], k: 1)
      expect(results.size).to eq(1)
      expect(results.first[:id]).to eq("doc1")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: inferred / search_before_add / mismatch  [SKIP — infeasible]
  #
  # When dimension is inferred (nil) and #search is called before any #add,
  # @expected_dimension is nil so no validation occurs regardless of embedding
  # size.  The mismatch factor has no observable effect.
  # ---------------------------------------------------------------------------
  describe "TC-006: inferred / search_before_add / mismatch [SKIP]" do
    # SKIP: infeasible — validate_embedding_dimension! is a no-op when
    # expected_dimension is nil; mismatch cannot be observed before first add.
    xit "SKIP: infeasible — no dimension established before first add" do
    end
  end
end
