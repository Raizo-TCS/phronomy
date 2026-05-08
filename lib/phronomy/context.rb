# frozen_string_literal: true

module Phronomy
  # Context management utilities: token estimation, budget calculation, and
  # context assembly.
  #
  # Sub-modules are auto-loaded by Zeitwerk:
  #   Phronomy::Context::TokenEstimator
  #   Phronomy::Context::TokenBudget
  #   Phronomy::Context::Builder
  module Context
  end
end

require_relative "context/assembler"
