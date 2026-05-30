# frozen_string_literal: true

module Phronomy
  # Document loader implementations for ingesting files into a RAG pipeline.
  #
  # Sub-classes are auto-loaded by Zeitwerk:
  #   Phronomy::Agent::Context::Knowledge::Loader::Base
  #   Phronomy::Agent::Context::Knowledge::Loader::PlainTextLoader
  #   Phronomy::Agent::Context::Knowledge::Loader::MarkdownLoader
  #   Phronomy::Agent::Context::Knowledge::Loader::CsvLoader
  module Loader
  end
end
