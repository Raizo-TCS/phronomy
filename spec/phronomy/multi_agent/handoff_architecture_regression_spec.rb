# frozen_string_literal: true

require "spec_helper"

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

  it "uses the shared Selection namespace instead of the removed Context selection constants" do
    expect(File).not_to exist(File.join(root, "lib/phronomy/agent/context_candidate.rb"))
    expect(File).not_to exist(File.join(root, "lib/phronomy/agent/context_selection_unit.rb"))
    expect(Phronomy::Agent::Selection::Candidate).to be_a(Class)
    expect(Phronomy::Agent::Selection::Unit).to be_a(Class)
  end

  it "keeps Handoff control out of ordinary Tool results" do
    request = File.read(File.join(root, "lib/phronomy/multi_agent/handoff_request.rb"))
    coordinator = File.read(File.join(root, "lib/phronomy/multi_agent/execution_coordinator.rb"))
    expect(request).to include("HandoffRequest")
    expect(coordinator).to include(":handed_off")
    expect(coordinator).not_to include("sentinel_map")
  end
end
