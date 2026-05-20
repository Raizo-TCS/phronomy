# frozen_string_literal: true

require "spec_helper"

# Pgvector backend requires the pgvector gem and a real PostgreSQL database.
# Unit tests here mock the ActiveRecord model class and the pgvector gem.

RSpec.describe Phronomy::VectorStore::Pgvector do
  # Fake pgvector gem presence so tests run without the real gem.
  before do
    allow_any_instance_of(described_class).to receive(:require).with("pgvector")
  end

  # A minimal ActiveRecord model double.
  let(:connection) do
    dbl = instance_double("ActiveRecord::ConnectionAdapters::AbstractAdapter")
    allow(dbl).to receive(:quote) { |val| "'#{val.to_s.gsub("'", "''")}'" }
    dbl
  end

  let(:model_class) do
    dbl = class_double("VectorDocument")
    allow(dbl).to receive(:connection).and_return(connection)
    dbl
  end

  subject(:store) { described_class.new(model_class: model_class) }

  describe "#add" do
    it "calls upsert on the model class with serialised data and returns self" do
      expect(model_class).to receive(:upsert).with(
        {id: "doc1", embedding: "[1.0,0.0]", metadata: '{"label":"A"}'},
        unique_by: :id
      )
      result = store.add(id: "doc1", embedding: [1.0, 0.0], metadata: {label: "A"})
      expect(result).to eq(store)
    end
  end

  describe "#search" do
    it "queries with cosine distance ordering and returns mapped results" do
      row = instance_double("VectorDocument",
        id: "doc1",
        score: 0.95,
        metadata: '{"label":"A"}')

      rel = instance_double("ActiveRecord::Relation")
      allow(model_class).to receive(:select).and_return(rel)
      allow(rel).to receive(:order).and_return(rel)
      allow(rel).to receive(:limit).and_return([row])

      results = store.search(query_embedding: [1.0, 0.0], k: 1)
      expect(results.size).to eq(1)
      expect(results.first[:id]).to eq("doc1")
      expect(results.first[:score]).to be_a(Float)
      expect(results.first[:metadata]).to eq({label: "A"})
    end
  end

  describe "#clear" do
    it "calls delete_all on the model class and returns self" do
      expect(model_class).to receive(:delete_all)
      expect(store.clear).to eq(store)
    end
  end

  describe "#remove" do
    it "calls where(id:).delete_all on the model class and returns self" do
      relation = double("relation")
      expect(model_class).to receive(:where).with(id: "doc1").and_return(relation)
      expect(relation).to receive(:delete_all)
      expect(store.remove(id: "doc1")).to eq(store)
    end
  end

  describe "inheritance" do
    it "inherits from Phronomy::VectorStore::Base" do
      expect(described_class.ancestors).to include(Phronomy::VectorStore::Base)
    end
  end

  describe "LoadError when pgvector gem is absent" do
    it "raises LoadError with a helpful message" do
      allow_any_instance_of(described_class).to receive(:require).with("pgvector").and_raise(LoadError)
      expect { described_class.new(model_class: model_class) }
        .to raise_error(LoadError, /pgvector gem/)
    end
  end

  # Regression tests for Issue #98: embedding dimension validation
  describe "dimension validation (Issue #98)" do
    context "when dimension: is specified" do
      subject(:store) { described_class.new(model_class: model_class, dimension: 2) }

      it "raises ArgumentError on add with wrong dimension" do
        expect { store.add(id: "a", embedding: [1.0, 0.0, 0.5], metadata: {}) }
          .to raise_error(ArgumentError, /dimension mismatch.*expected 2.*got 3/i)
      end

      it "raises ArgumentError on search with wrong dimension" do
        expect { store.search(query_embedding: [1.0, 0.0, 0.5]) }
          .to raise_error(ArgumentError, /dimension mismatch.*expected 2.*got 3/i)
      end

      it "accepts add with matching dimension" do
        allow(model_class).to receive(:upsert)
        expect { store.add(id: "a", embedding: [1.0, 0.0], metadata: {}) }.not_to raise_error
      end
    end

    context "when dimension: is not specified" do
      it "does not raise on add regardless of embedding size" do
        allow(model_class).to receive(:upsert)
        expect { store.add(id: "a", embedding: [1.0, 0.0, 0.5], metadata: {}) }.not_to raise_error
      end
    end
  end
end
