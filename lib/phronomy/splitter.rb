# frozen_string_literal: true

module Phronomy
  # Text splitter implementations for chunking documents before embedding.
  #
  # Sub-classes are auto-loaded by Zeitwerk:
  #   Phronomy::Agent::Context::Knowledge::Splitter::Base
  #   Phronomy::Agent::Context::Knowledge::Splitter::FixedSizeSplitter
  #   Phronomy::Agent::Context::Knowledge::Splitter::RecursiveSplitter
  module Splitter
  end
end
