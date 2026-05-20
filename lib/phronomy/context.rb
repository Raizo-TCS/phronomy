# frozen_string_literal: true

module Phronomy
  # Context management utilities: token estimation, budget calculation, and
  # context assembly.
  #
  # Sub-modules are auto-loaded by Zeitwerk:
  #   Phronomy::Context::TokenEstimator
  #   Phronomy::Context::TokenBudget
  module Context
  end
end

require_relative "context/assembler"
require_relative "context/context_version_cache"
require_relative "context/trim_context"
require_relative "context/trigger_context"
require_relative "context/compaction_context"
