# frozen_string_literal: true

module Phronomy
  # Text splitter implementations for chunking documents before embedding.
  #
  # Sub-classes are auto-loaded by Zeitwerk:
  #   Phronomy::RAG::Splitter::Base
  #   Phronomy::RAG::Splitter::FixedSizeSplitter
  #   Phronomy::RAG::Splitter::RecursiveSplitter
  module Splitter
  end
end
