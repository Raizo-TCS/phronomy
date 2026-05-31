# frozen_string_literal: true

module Phronomy
  # Vector store infrastructure: backends, embeddings adapters, document loaders,
  # and text splitters.
  #
  # Sub-namespaces are auto-loaded by Zeitwerk:
  #   Phronomy::VectorStore::Base
  #   Phronomy::VectorStore::InMemory
  #   Phronomy::VectorStore::Pgvector
  #   Phronomy::VectorStore::RedisSearch
  #   Phronomy::VectorStore::Embeddings::Base
  #   Phronomy::VectorStore::Embeddings::RubyLLMEmbeddings
  #   Phronomy::VectorStore::Loader::Base
  #   Phronomy::VectorStore::Loader::PlainTextLoader
  #   Phronomy::VectorStore::Loader::MarkdownLoader
  #   Phronomy::VectorStore::Loader::CsvLoader
  #   Phronomy::VectorStore::Splitter::Base
  #   Phronomy::VectorStore::Splitter::FixedSizeSplitter
  #   Phronomy::VectorStore::Splitter::RecursiveSplitter
  module VectorStore
  end
end
