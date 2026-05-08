# frozen_string_literal: true

module Phronomy
  # Document loader implementations for ingesting files into a RAG pipeline.
  #
  # Sub-classes are auto-loaded by Zeitwerk:
  #   Phronomy::Loader::Base
  #   Phronomy::Loader::PlainTextLoader
  #   Phronomy::Loader::MarkdownLoader
  #   Phronomy::Loader::CsvLoader
  module Loader
  end
end
