# frozen_string_literal: true

require "spec_helper"
require_relative "../../support/shared_examples/a_content_store"
require_relative "../../support/shared_examples/an_agent_repository"
require_relative "../../support/shared_examples/a_journal_repository"
require_relative "../../support/shared_examples/an_execution_repository"
require_relative "../../support/shared_examples/a_workflow_state_repository"
require_relative "../../support/shared_examples/a_persistence_backend"

RSpec.describe "Persistence backend contract" do
  context "with Persistence::InMemory" do
    let(:persistence) { Phronomy::Persistence::InMemory.new }

    it_behaves_like "a persistence content store"
    it_behaves_like "an Agent repository"
    it_behaves_like "a Journal repository"
    it_behaves_like "an Execution repository"
    it_behaves_like "a workflow state repository"
    it_behaves_like "a Persistence backend"
  end
end
