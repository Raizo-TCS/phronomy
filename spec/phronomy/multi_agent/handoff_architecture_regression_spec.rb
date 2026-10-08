# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "CG-05 Handoff architecture regression guards" do
  let(:root) { File.expand_path("../../..", __dir__) }

  it "does not expose the removed sentinel Handoff encoding" do
    source = File.read(File.join(root, "lib/phronomy/multi_agent/handoff.rb"))
    expect(source).not_to include("SENTINEL_PREFIX")
    expect(source).not_to include("def sentinel")
    expect(source).not_to include("def to_tool_class")
  end

  it "does not keep the old Agent-owned Handoff Tool registry" do
    source = File.read(File.join(root, "lib/phronomy/agent/base.rb"))
    expect(source).not_to include("def _add_handoff_tool")
    expect(source).not_to include("def _handoff_tools")
  end

  it "keeps only the internal Selection candidate normalization used by Context assembly" do
    expect(File).not_to exist(File.join(root, "lib/phronomy/agent/context_candidate.rb"))
    expect(File).not_to exist(File.join(root, "lib/phronomy/agent/context_selection_unit.rb"))
    expect(Phronomy::Context::Candidate).to be_a(Class)
    expect(Phronomy::Context.const_defined?(:Unit, false)).to be(false)
  end

  it "does not restore the removed Agent::Runner public surface" do
    expect(File).not_to exist(File.join(root, "lib/phronomy/agent/runner.rb"))
    expect(Phronomy::Agent.const_defined?(:Runner, false)).to be(false)
    expect(Phronomy::MultiAgent::HandoffRunner).to be_a(Class)
    expect(Phronomy::Agent.const_defined?(:HandoffRunner, false)).to be(false)
  end

  it "constructs ordinary Agents without loading MultiAgent types or routing schema" do
    source = <<~RUBY
      require "phronomy"
      Phronomy.send(:remove_const, :MultiAgent)
      klass = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "handoff-boundary", version: 1
      end
      store = Phronomy::PersistenceComposition.agent
      first = klass.create(persistence: store)
      second = klass.create(persistence: store)
      abort "Agent schema contains routing" if Phronomy::PersistenceComposition::StorageSchema.agent_resources.any? { |resource| resource.id == "handoff.states" }
      abort "Agent loaded MultiAgent" if Phronomy.const_defined?(:MultiAgent, false)
      abort "incomplete shutdown" unless Phronomy::Runtime.instance.shutdown.cleanup_complete?
    RUBY
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I", File.join(root, "lib"), "-e", source
    )
    expect(status.success?).to be(true), [stdout, stderr].join("\n")
  end

  it "keeps Handoff control out of ordinary Tool results" do
    request = File.read(File.join(root, "lib/phronomy/agent/control_request.rb"))
    participant = File.read(File.join(root, "lib/phronomy/multi_agent/handoff_participant.rb"))
    worker = File.read(File.join(root, "lib/phronomy/agent/execution/execution_outcome_committer.rb"))
    expect(request).to include("ControlRequest")
    expect(participant).to include("change.commit_in(scope")
    expect(worker).to include(":handed_off")
    expect(worker).not_to include("handoff_states", "MultiAgent", "sentinel_map")
    expect(File).not_to exist(File.join(root, "lib/phronomy/agent/handoff/handoff_execution_coordinator.rb"))
  end

  it "does not leave removed CG-05 production identifiers in lib" do
    production = Dir[File.join(root, "lib/**/*.rb")].sort.to_h do |path|
      [path.sub("#{root}/", ""), File.read(path)]
    end
    expect(production.values.join("\n")).not_to include("SENTINEL_PREFIX")
    expect(production.values.join("\n")).not_to include("def _add_handoff_tool")
    expect(production.values.join("\n")).not_to include("def _handoff_tools")
    expect(production.keys).not_to include("lib/phronomy/agent/context_candidate.rb")
    expect(production.keys).not_to include("lib/phronomy/agent/context_selection_unit.rb")
    expect(production.keys).not_to include("lib/phronomy/agent/runner.rb")
  end
end
