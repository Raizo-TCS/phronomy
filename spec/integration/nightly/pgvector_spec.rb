# frozen_string_literal: true

require "spec_helper"

# Nightly spec: VectorStore::Pgvector against a real PostgreSQL + pgvector DB.
#
# Required environment variables:
#   PGVECTOR_DATABASE_URL — e.g. postgresql://user:pass@localhost:5432/dbname
#   NIGHTLY=1
#
# Run with: bundle exec rspec spec/integration/nightly/pgvector_spec.rb --tag nightly
# Note: requires gem install pg pgvector activerecord before running.
#
# These tests are skipped locally unless PGVECTOR_DATABASE_URL and NIGHTLY are set.
# They run automatically in CI via .github/workflows/nightly.yml (real-backend-pgvector job).

if ENV["NIGHTLY"] && ENV["PGVECTOR_DATABASE_URL"]
  begin
    require "active_record"
    require "pgvector"
  rescue LoadError => e
    warn "Skipping pgvector nightly spec: #{e.message}"
  end
end

PGVECTOR_AVAILABLE = defined?(ActiveRecord) && defined?(Pgvector) && ENV["PGVECTOR_DATABASE_URL"]

RSpec.describe "Nightly: VectorStore::Pgvector against real PostgreSQL", :nightly, real_backend: :pgvector do
  before(:all) do
    skip "Skipped: PGVECTOR_DATABASE_URL not set or required gems missing" unless PGVECTOR_AVAILABLE

    ActiveRecord::Base.establish_connection(ENV.fetch("PGVECTOR_DATABASE_URL"))
    ActiveRecord::Base.connection.enable_extension("vector")

    ActiveRecord::Schema.define do
      create_table :phronomy_nightly_docs, force: true do |t|
        t.string :id, null: false, primary_key: true
        t.column :embedding, :vector, limit: 3
        t.text :metadata
      end

      create_table :phronomy_nightly_empty_docs, force: true do |t|
        t.string :id, null: false, primary_key: true
        t.column :embedding, :vector, limit: 3
        t.text :metadata
      end
    end

    # Minimal AR models for tests.
    stub_const("NightlyDoc", Class.new(ActiveRecord::Base) do
      self.table_name = "phronomy_nightly_docs"
      self.primary_key = "id"
    end)

    stub_const("NightlyEmptyDoc", Class.new(ActiveRecord::Base) do
      self.table_name = "phronomy_nightly_empty_docs"
      self.primary_key = "id"
    end)
  end

  after(:all) do
    if PGVECTOR_AVAILABLE
      ActiveRecord::Base.connection.drop_table(:phronomy_nightly_docs, if_exists: true)
      ActiveRecord::Base.connection.drop_table(:phronomy_nightly_empty_docs, if_exists: true)
    end
  end

  let(:store) { Phronomy::VectorStore::Pgvector.new(model_class: NightlyDoc, dimension: 3) }

  it "adds a document and retrieves it via search" do
    skip "Requires real PostgreSQL with pgvector" unless PGVECTOR_AVAILABLE
    store.add(id: "doc1", embedding: [0.9, 0.1, 0.0], metadata: {text: "hello"})
    results = store.search(query_embedding: [0.9, 0.1, 0.0], k: 1)
    expect(results.length).to eq(1)
    expect(results.first[:id]).to eq("doc1")
    expect(results.first[:metadata][:text]).to eq("hello")
    expect(results.first[:score]).to be_within(0.01).of(1.0)
  end

  it "removes a document" do
    skip "Requires real PostgreSQL with pgvector" unless PGVECTOR_AVAILABLE
    store.add(id: "rm1", embedding: [0.5, 0.5, 0.0], metadata: {})
    store.remove(id: "rm1")
    results = store.search(query_embedding: [0.5, 0.5, 0.0], k: 5)
    expect(results.map { |r| r[:id] }).not_to include("rm1")
  end

  it "clears all documents" do
    skip "Requires real PostgreSQL with pgvector" unless PGVECTOR_AVAILABLE
    store.add(id: "cl1", embedding: [0.1, 0.2, 0.3], metadata: {})
    store.add(id: "cl2", embedding: [0.4, 0.5, 0.6], metadata: {})
    store.clear
    results = store.search(query_embedding: [0.1, 0.2, 0.3], k: 10)
    expect(results).to be_empty
  end

  it "returns results ordered by descending similarity" do
    skip "Requires real PostgreSQL with pgvector" unless PGVECTOR_AVAILABLE
    store.clear
    store.add(id: "near", embedding: [1.0, 0.0, 0.0], metadata: {})
    store.add(id: "far", embedding: [0.0, 1.0, 0.0], metadata: {})
    results = store.search(query_embedding: [1.0, 0.0, 0.0], k: 2)
    expect(results.first[:id]).to eq("near")
    expect(results.last[:id]).to eq("far")
  end

  it "raises ArgumentError for dimension mismatch" do
    skip "Requires real PostgreSQL with pgvector" unless PGVECTOR_AVAILABLE
    expect {
      store.add(id: "bad", embedding: [1.0, 0.0], metadata: {})
    }.to raise_error(ArgumentError, /dimension/i)
  end

  # Contract tests: verify that Pgvector satisfies the a_vector_store interface.
  # The outer before(:all) sets up the real DB schema; each contract example
  # clears the tables to start from a known-empty state.
  it_behaves_like "a vector store" do
    before do
      skip "Requires real PostgreSQL with pgvector" unless PGVECTOR_AVAILABLE
      NightlyDoc.delete_all
      NightlyEmptyDoc.delete_all
    end

    let(:store) { Phronomy::VectorStore::Pgvector.new(model_class: NightlyDoc, dimension: 3) }
    let(:empty_store) { Phronomy::VectorStore::Pgvector.new(model_class: NightlyEmptyDoc, dimension: 3) }
  end
end
