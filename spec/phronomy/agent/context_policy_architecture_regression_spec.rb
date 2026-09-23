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
    source = File.read(File.join(root, "lib/phronomy/agent/execution/execution_coordinator.rb"))
    source += File.read(File.join(root, "lib/phronomy/agent/execution/dispatch_preparation.rb"))
    source += File.read(File.join(root, "lib/phronomy/agent/execution/initial_preparation.rb"))
    expect(source).not_to include("ContextPolicyDescriptor")
    expect(source).not_to include("ContextPolicyRegistry")
    expect(source).not_to include("def context_policy_for")
    expect(source).not_to include('"context_policy" =>')
  end

  it "runs initial Policy preparation before the mutable-state commit transaction" do
    worker = File.read(File.join(root, "lib/phronomy/agent/execution/initial_preparation.rb"))
    preparation = worker.split("def prepare_admitted", 2).fetch(1).split(/^      def /, 2).first
    context = worker.split("def prepare_context", 2).fetch(1).split(/^      def /, 2).first
    commit = worker.split("def commit_preparation(", 2).fetch(1).split(/^      def /, 2).first

    expect(preparation.index("prepare_context")).to be < preparation.index("commit_preparation")
    expect(context).to include("assembler.prepare_initial", "invocation cancelled after context policy")
    expect(context).not_to include(".transaction")
    expect(commit.index("assert_local_durable_base!")).to be < commit.index("assembler.finalize")
    expect(commit.index("assembler.finalize")).to be < commit.index("tx.executions.save")
  end

  it "runs follow-up Policy between snapshot encoding and the durable state commit" do
    worker = File.read(File.join(root, "lib/phronomy/agent/execution/dispatch_preparation.rb"))
    preparation = worker.split("def prepare_provider(operation)", 2).fetch(1).split(/^      def /, 2).first
    context = worker.split("def prepare_provider_context", 2).fetch(1).split(/^      def /, 2).first
    encoding = worker.split("def encode_provider_records", 2).fetch(1).split(/^      def /, 2).first
    commit = worker.split("def commit_provider_preparation", 2).fetch(1).split(/^      def /, 2).first

    expect(preparation.index("encode_provider_records")).to be < preparation.index("prepare_provider_context")
    expect(preparation.index("prepare_provider_context")).to be < preparation.index("commit_provider_preparation")
    expect(context).to include("assembler.prepare_followup", "invocation cancelled after context policy")
    expect(context).not_to include(".transaction")
    [encoding, commit].each do |section|
      expect(section).to include("@persistence.transaction do |tx|", "assert_local_durable_base!(tx, operation.root)")
    end
  end
end
