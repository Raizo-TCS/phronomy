# frozen_string_literal: true

module Phronomy
  # Text splitter implementations for chunking documents before embedding.
  #
  # Sub-classes are auto-loaded by Zeitwerk:
  #   Phronomy::Splitter::Base
  #   Phronomy::Splitter::FixedSizeSplitter
  #   Phronomy::Splitter::RecursiveSplitter
  module Splitter
  end
end
