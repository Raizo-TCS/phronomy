# frozen_string_literal: true

require "phronomy"

begin
  require "rspec/core"
  require "rspec/expectations"
rescue LoadError => error
  raise LoadError,
    "Phronomy Persistence contract support requires RSpec. " \
    "Add `rspec` to the backend project's development/test dependencies before " \
    "requiring `phronomy/testing/persistence_contract`.",
    error.backtrace
end

module Phronomy
  module Testing
    # Explicitly loaded RSpec shared examples for Persistence backend authors.
    #
    # This namespace is intentionally excluded from Phronomy's production
    # Zeitwerk eager-load path. Requiring this file is the opt-in boundary that
    # loads RSpec and the backend conformance suite.
    module PersistenceContract
      SHARED_EXAMPLES = [
        "a persistence content store",
        "an Agent repository",
        "a Journal repository",
        "an Execution repository",
        "a workflow state repository",
        "a Persistence backend"
      ].freeze
    end
  end
end

require_relative "persistence_contract/a_content_store"
require_relative "persistence_contract/an_agent_repository"
require_relative "persistence_contract/a_journal_repository"
require_relative "persistence_contract/an_execution_repository"
require_relative "persistence_contract/a_workflow_state_repository"
require_relative "persistence_contract/a_persistence_backend"
