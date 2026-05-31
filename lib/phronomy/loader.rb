# frozen_string_literal: true

module Phronomy
  # Document loader implementations for ingesting files into a RAG pipeline.
  #
  # Sub-classes are auto-loaded by Zeitwerk:
  #   Phronomy::RAG::Loader::Base
  #   Phronomy::RAG::Loader::PlainTextLoader
  #   Phronomy::RAG::Loader::MarkdownLoader
  #   Phronomy::RAG::Loader::CsvLoader
  module Loader
  end
end
