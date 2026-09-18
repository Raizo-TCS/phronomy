# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "CG-05 Handoff architecture regression guards" do
  let(:root) { File.expand_path("../../..", __dir__) }

  it "does not expose the removed sentinel Handoff encoding" do
    source = File.read(File.join(root, "lib/phronomy/agent/handoff.rb"))
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
    expect(Phronomy::Agent::Selection::Candidate).to be_a(Class)
    expect(Phronomy::Agent::Selection.const_defined?(:Unit, false)).to be(false)
  end

  it "does not restore the removed Agent::Runner public surface" do
    expect(File).not_to exist(File.join(root, "lib/phronomy/agent/runner.rb"))
    expect(Phronomy::Agent.const_defined?(:Runner, false)).to be(false)
    expect(Phronomy::MultiAgent::HandoffRunner).to be_a(Class)
    expect(Phronomy::Agent.const_defined?(:HandoffRunner, false)).to be(false)
  end

  it "constructs ordinary Agents and Handoff edges without the MultiAgent implementation" do
    source = <<~RUBY
      require "phronomy"
      Phronomy.send(:remove_const, :MultiAgent)
      klass = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "handoff-boundary", version: 1
      end
      store = Phronomy::Persistence.in_memory
      first = klass.create(persistence: store)
      second = klass.create(persistence: store)
      edge = Phronomy::Agent::Handoff.new(source_agent: first, target_agent: second)
      abort "wrong target" unless edge.target_agent.equal?(second)
      abort "Agent loaded MultiAgent" if Phronomy.const_defined?(:MultiAgent, false)
      abort "incomplete shutdown" unless Phronomy::Runtime.instance.shutdown.cleanup_complete?
    RUBY
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I", File.join(root, "lib"), "-e", source
    )
    expect(status.success?).to be(true), [stdout, stderr].join("\n")
  end

  it "keeps Handoff control out of ordinary Tool results" do
    request = File.read(File.join(root, "lib/phronomy/agent/handoff_request.rb"))
    coordinator = File.read(File.join(root, "lib/phronomy/agent/handoff_execution_coordinator.rb"))
    expect(request).to include("HandoffRequest")
    expect(coordinator).to include(":handed_off")
    expect(coordinator).not_to include("sentinel_map")
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
