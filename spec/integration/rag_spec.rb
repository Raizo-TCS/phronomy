# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require "tempfile"

# Group 15: Document Loaders and Text Splitters for RAG
#
# Factors:
#   F1: loader_type   = [plain_text, markdown_with_headings, markdown_no_split, csv_with_headers]
#   F2: splitter_type = [none, fixed_size, recursive]
#   F3: rag_pipeline  = [loader_only, loader_splitter, loader_splitter_embed_store]
#
# Generated pairwise cases: 13 (see docs/integration_test_cases_rag.yaml)
#
# Infeasible cases (SKIP):
#   TC-004: markdown_with_headings + splitter_type=none + rag_pipeline=loader_splitter
#           rag_pipeline=loader_splitter requires a non-nil splitter; splitter_type=none is contradictory
#
# Feasible pairwise cases without LLM: TC-001, TC-002, TC-005, TC-006, TC-008, TC-010, TC-011, TC-012
# Cases with rag_pipeline=loader_splitter_embed_store (LLM required): TC-003, TC-007, TC-009, TC-013

RSpec.describe "Group 15: Document Loaders and Text Splitters for RAG", :integration do
  # Helpers -------------------------------------------------------------------

  # Build a temporary plain-text file.
  def make_plain_text_file
    f = Tempfile.new(["phronomy_test", ".txt"])
    f.write("Hello World\n\nThis is a plain text document.")
    f.flush
    f
  end

  # Build a temporary Markdown file with headings.
  def make_markdown_file
    f = Tempfile.new(["phronomy_test", ".md"])
    f.write(<<~MD)
      # Introduction

      Welcome to the guide.

      ## Section One

      This section covers the basics.

      ## Section Two

      This section covers advanced topics.
    MD
    f.flush
    f
  end

  # Build a temporary CSV file with header row.
  def make_csv_file
    f = Tempfile.new(["phronomy_test", ".csv"])
    f.write(<<~CSV)
      name,description
      Ruby,A dynamic object-oriented language
      Python,A high-level general-purpose language
      Go,A statically typed compiled language
    CSV
    f.flush
    f
  end

  # Embed stub that generates fake vectors without calling an LLM.
  let(:stub_embeddings) do
    IntegrationFactors::StubEmbeddings.new
  end

  # ---------------------------------------------------------------------------
  # TC-001: plain_text + none + loader_only
  # ---------------------------------------------------------------------------
  it "TC-001: PlainTextLoader returns a single document" do
    file = make_plain_text_file
    loader = IntegrationFactors.loader("plain_text")
    docs = loader.load(file.path)

    expect(docs).to be_an(Array)
    expect(docs.size).to eq(1)
    expect(docs.first[:text]).to include("Hello World")
    expect(docs.first[:metadata][:source]).to eq(file.path)
  ensure
    file.close
    file.unlink
  end

  # ---------------------------------------------------------------------------
  # TC-002: plain_text + fixed_size + loader_splitter
  # ---------------------------------------------------------------------------
  it "TC-002: PlainTextLoader + FixedSizeSplitter splits into chunks" do
    file = make_plain_text_file
    loader = IntegrationFactors.loader("plain_text")
    splitter = IntegrationFactors.splitter("fixed_size")

    docs = loader.load(file.path)
    chunks = splitter.split_all(docs)

    expect(chunks).to be_an(Array)
    expect(chunks).not_to be_empty
    chunks.each do |chunk|
      expect(chunk[:text].length).to be <= 200
      expect(chunk[:metadata]).to have_key(:chunk)
    end
  ensure
    file.close
    file.unlink
  end

  # ---------------------------------------------------------------------------
  # TC-003: plain_text + recursive + loader_splitter_embed_store (LLM required)
  # ---------------------------------------------------------------------------
  it "TC-003: PlainTextLoader + RecursiveSplitter + embed + store", :llm_required do
    file = make_plain_text_file
    loader = IntegrationFactors.loader("plain_text")
    splitter = IntegrationFactors.splitter("recursive")
    vector_store = IntegrationFactors.vector_store("in_memory")

    docs = loader.load(file.path)
    chunks = splitter.split_all(docs)
    items = chunks.map.with_index(1) { |c, i| {id: i, embedding: stub_embeddings.embed(c[:text]), metadata: c[:metadata].merge(text: c[:text])} }
    items.each { |item| vector_store.add(**item) }

    expect(vector_store.size).to eq(items.size)
  ensure
    file.close
    file.unlink
  end

  # ---------------------------------------------------------------------------
  # TC-004: markdown_with_headings + none + loader_splitter — SKIP (infeasible)
  # Reason: rag_pipeline=loader_splitter requires a non-nil splitter; splitter_type=none is contradictory
  # ---------------------------------------------------------------------------
  xit "TC-004: SKIP — splitter_type=none is incompatible with rag_pipeline=loader_splitter"

  # ---------------------------------------------------------------------------
  # TC-005: markdown_with_headings + fixed_size + loader_only
  # (splitter_type fixed_size is irrelevant for loader_only; loader result verified)
  # ---------------------------------------------------------------------------
  it "TC-005: MarkdownLoader with headings produces per-section documents" do
    file = make_markdown_file
    loader = IntegrationFactors.loader("markdown_with_headings")

    docs = loader.load(file.path)

    expect(docs.size).to be >= 2
    sections = docs.map { |d| d[:metadata][:section] }.compact
    expect(sections).not_to be_empty
  ensure
    file.close
    file.unlink
  end

  # ---------------------------------------------------------------------------
  # TC-006: markdown_with_headings + recursive + loader_only
  # ---------------------------------------------------------------------------
  it "TC-006: MarkdownLoader with headings returns documents with section metadata" do
    file = make_markdown_file
    loader = IntegrationFactors.loader("markdown_with_headings")

    docs = loader.load(file.path)

    expect(docs).to be_an(Array)
    docs.each do |doc|
      expect(doc).to have_key(:text)
      expect(doc).to have_key(:metadata)
      expect(doc[:metadata][:source]).to eq(file.path)
    end
  ensure
    file.close
    file.unlink
  end

  # ---------------------------------------------------------------------------
  # TC-007: markdown_with_headings + none + loader_splitter_embed_store (LLM required)
  # ---------------------------------------------------------------------------
  it "TC-007: MarkdownLoader with headings + embed + store (no extra splitting)", :llm_required do
    file = make_markdown_file
    loader = IntegrationFactors.loader("markdown_with_headings")
    vector_store = IntegrationFactors.vector_store("in_memory")

    docs = loader.load(file.path)
    items = docs.map.with_index(1) { |d, i| {id: i, embedding: stub_embeddings.embed(d[:text]), metadata: d[:metadata].merge(text: d[:text])} }
    items.each { |item| vector_store.add(**item) }

    expect(vector_store.size).to eq(docs.size)
  ensure
    file.close
    file.unlink
  end

  # ---------------------------------------------------------------------------
  # TC-008: markdown_no_split + none + loader_only
  # ---------------------------------------------------------------------------
  it "TC-008: MarkdownLoader without heading-split returns a single document" do
    file = make_markdown_file
    loader = IntegrationFactors.loader("markdown_no_split")

    docs = loader.load(file.path)

    expect(docs.size).to eq(1)
    expect(docs.first[:text]).to include("Introduction")
    expect(docs.first[:text]).to include("Section One")
  ensure
    file.close
    file.unlink
  end

  # ---------------------------------------------------------------------------
  # TC-009: markdown_no_split + fixed_size + loader_splitter_embed_store (LLM required)
  # ---------------------------------------------------------------------------
  it "TC-009: MarkdownLoader no-split + FixedSizeSplitter + embed + store", :llm_required do
    file = make_markdown_file
    loader = IntegrationFactors.loader("markdown_no_split")
    splitter = IntegrationFactors.splitter("fixed_size")
    vector_store = IntegrationFactors.vector_store("in_memory")

    docs = loader.load(file.path)
    chunks = splitter.split_all(docs)
    items = chunks.map.with_index(1) { |c, i| {id: i, embedding: stub_embeddings.embed(c[:text]), metadata: c[:metadata].merge(text: c[:text])} }
    items.each { |item| vector_store.add(**item) }

    expect(vector_store.size).to eq(items.size)
  ensure
    file.close
    file.unlink
  end

  # ---------------------------------------------------------------------------
  # TC-010: markdown_no_split + recursive + loader_splitter
  # ---------------------------------------------------------------------------
  it "TC-010: MarkdownLoader no-split + RecursiveSplitter splits into chunks" do
    file = make_markdown_file
    loader = IntegrationFactors.loader("markdown_no_split")
    splitter = IntegrationFactors.splitter("recursive")

    docs = loader.load(file.path)
    chunks = splitter.split_all(docs)

    expect(chunks).to be_an(Array)
    expect(chunks).not_to be_empty
    chunks.each { |chunk| expect(chunk[:text].length).to be <= 200 }
  ensure
    file.close
    file.unlink
  end

  # ---------------------------------------------------------------------------
  # TC-011: csv_with_headers + none + loader_only
  # ---------------------------------------------------------------------------
  it "TC-011: CsvLoader with headers returns one document per data row" do
    file = make_csv_file
    loader = IntegrationFactors.loader("csv_with_headers")

    docs = loader.load(file.path)

    expect(docs.size).to eq(3)
    docs.each do |doc|
      expect(doc[:text]).to include("name:")
      expect(doc[:text]).to include("description:")
      expect(doc[:metadata][:source]).to eq(file.path)
      expect(doc[:metadata][:row]).to be_an(Integer)
    end
  ensure
    file.close
    file.unlink
  end

  # ---------------------------------------------------------------------------
  # TC-012: csv_with_headers + fixed_size + loader_splitter
  # ---------------------------------------------------------------------------
  it "TC-012: CsvLoader + FixedSizeSplitter splits row text into chunks" do
    file = make_csv_file
    loader = IntegrationFactors.loader("csv_with_headers")
    splitter = IntegrationFactors.splitter("fixed_size")

    docs = loader.load(file.path)
    chunks = splitter.split_all(docs)

    expect(chunks).to be_an(Array)
    expect(chunks).not_to be_empty
    chunks.each { |chunk| expect(chunk[:text].length).to be <= 200 }
  ensure
    file.close
    file.unlink
  end

  # ---------------------------------------------------------------------------
  # TC-013: csv_with_headers + recursive + loader_splitter_embed_store (LLM required)
  # ---------------------------------------------------------------------------
  it "TC-013: CsvLoader + RecursiveSplitter + embed + store", :llm_required do
    file = make_csv_file
    loader = IntegrationFactors.loader("csv_with_headers")
    splitter = IntegrationFactors.splitter("recursive")
    vector_store = IntegrationFactors.vector_store("in_memory")

    docs = loader.load(file.path)
    chunks = splitter.split_all(docs)
    items = chunks.map.with_index(1) { |c, i| {id: i, embedding: stub_embeddings.embed(c[:text]), metadata: c[:metadata].merge(text: c[:text])} }
    items.each { |item| vector_store.add(**item) }

    expect(vector_store.size).to eq(items.size)
  ensure
    file.close
    file.unlink
  end
end
