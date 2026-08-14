# frozen_string_literal: true

require "spec_helper"
require_relative "../../support/shared_examples/a_workflow_state_repository"

RSpec.describe "Persistence workflow_states repository contract" do
  context "with Persistence::InMemory" do
    let(:persistence) { Phronomy::Persistence::InMemory.new }

    it_behaves_like "a workflow state repository"
  end
end
