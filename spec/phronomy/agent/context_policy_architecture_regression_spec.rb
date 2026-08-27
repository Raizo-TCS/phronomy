# frozen_string_literal: true

require "spec_helper"

RSpec.describe "ACS-04 Context Policy architecture regression guards" do
  let(:root) { File.expand_path("../../..", __dir__) }

  removed_paths = %w[
    lib/phronomy/agent/context_request.rb
    lib/phronomy/agent/context_policy_descriptor.rb
    lib/phronomy/agent/context_policy_registry.rb
    lib/phronomy/agent/derived_content_spec.rb
    lib/phronomy/agent/selection/unit.rb
    lib/phronomy/agent/selection/validator.rb
    lib/phronomy/agent/selection/unit_builders/dependency_aware_unit_builder.rb
    lib/phronomy/agent/selection/selectors/recent_first_selector.rb
    lib/phronomy/agent/context_parts/requirements/required_context_resolver.rb
    lib/phronomy/agent/context_parts/budget/token_budget_packer.rb
  ].freeze

  it "removes the superseded Context Policy implementation files" do
    removed_paths.each do |relative|
      expect(File).not_to exist(File.join(root, relative)), relative
    end
  end

  it "does not expose descriptor, registry, request, derived-content, or selection-unit constants" do
    expect(Phronomy::Agent.const_defined?(:ContextRequest, false)).to be(false)
    expect(Phronomy::Agent.const_defined?(:ContextPolicyDescriptor, false)).to be(false)
    expect(Phronomy::Agent.const_defined?(:ContextPolicyRegistry, false)).to be(false)
    expect(Phronomy::Agent.const_defined?(:DerivedContentSpec, false)).to be(false)
    expect(Phronomy::Agent::Selection.const_defined?(:Unit, false)).to be(false)
    expect(Phronomy::Agent::Selection.const_defined?(:Validator, false)).to be(false)
  end

  it "keeps Policy binding on the Agent class rather than create/load/invoke/stream overrides" do
    expect(Phronomy::Agent::Base).to respond_to(:context_policy)
    expect(Phronomy::Agent::Base.method(:create).parameters.flatten).not_to include(:context_policy)
    expect(Phronomy::Agent::Base.method(:load).parameters.flatten).not_to include(:context_policy)
    expect(Phronomy::Agent::Base.instance_method(:invoke).parameters.flatten).not_to include(:context_policy)
    expect(Phronomy::Agent::Base.instance_method(:stream).parameters.flatten).not_to include(:context_policy)
  end

  it "does not persist or reconstruct a ContextPolicy descriptor" do
    source = File.read(File.join(root, "lib/phronomy/agent/execution_coordinator.rb"))
    expect(source).not_to include("ContextPolicyDescriptor")
    expect(source).not_to include("ContextPolicyRegistry")
    expect(source).not_to include("def context_policy_for")
    expect(source).not_to include('"context_policy" =>')
  end

  it "runs initial Policy preparation before the mutable-state commit transaction" do
    source = File.read(File.join(root, "lib/phronomy/agent/execution_coordinator.rb"))
    section = source[/def perform_initial_preparation\(operation\).*?\n      def admit_execution/m]
    expect(section).not_to be_nil
    prepare_index = section.index("prepared = assembler.prepare_initial")
    commit_index = section.index("@agent.persistence.transaction do |tx|", prepare_index)
    expect(prepare_index).not_to be_nil
    expect(commit_index).not_to be_nil
    expect(commit_index).to be > prepare_index
    expect(section[prepare_index...commit_index]).to include("invocation cancelled after context policy")
  end

  it "runs follow-up Policy between snapshot encoding and the durable state commit" do
    source = File.read(File.join(root, "lib/phronomy/agent/execution_coordinator.rb"))
    section = source[/def perform_provider_dispatch_preparation\(operation\).*?\n      def perform_tool_dispatch_preparation/m]
    expect(section).not_to be_nil
    prepare_index = section.index("prepared = assembler.prepare_followup")
    transactions = []
    offset = 0
    needle = "@agent.persistence.transaction do |tx|"
    while (index = section.index(needle, offset))
      transactions << index
      offset = index + needle.length
    end
    expect(transactions.length).to be >= 2
    expect(transactions.first).to be < prepare_index
    expect(transactions.last).to be > prepare_index
    expect(section).to include("assert_local_durable_base!(tx, operation.root)")
  end
end
