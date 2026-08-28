# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Workstream 01 architecture authority closeout" do
  let(:root) { File.expand_path("../..", __dir__) }

  def read(relative_path)
    File.read(File.join(root, relative_path))
  end

  it "carries the accepted current design principles into the canonical architecture entry" do
    architecture = read("docs/architecture.md")

    expect(architecture).to include("## Design principles")
    expect(architecture).to include("Ruby-idiomatic application surface")
    expect(architecture).to include("Progressive adoption")
    expect(architecture).to include("Small and explicit core dependency surface")
    expect(architecture).to include("engineering preference, not a hard invariant")
  end

  it "supersedes ADR-001 with the current LLMAdapter provider-call boundary" do
    old_adr = read("docs/decisions/001-rubyllm-as-provider-layer.md")
    new_adr = read("docs/decisions/027-llm-adapter-provider-boundary.md")

    expect(old_adr).to include("## Status\n\nSuperseded")
    expect(old_adr).to include("027-llm-adapter-provider-boundary")

    expect(new_adr).to include("## Status\n\nAccepted")
    expect(new_adr).to include("Phronomy::LLMAdapter::Base#complete")
    expect(new_adr).to include("Phronomy::LLMAdapter::RubyLLM")
    expect(new_adr).to include("does not imply that the complete input-materialization pipeline is")
    expect(new_adr).to include("This decision supersedes")
    expect(new_adr).to include("001-rubyllm-as-provider-layer")
  end

  it "amends ADR-002 while retaining immutable merge semantics and EventLoop-owned field mutation" do
    adr = read("docs/decisions/002-workflow-context-immutability.md")

    expect(adr).to include("## Status\n\nAmended")
    expect(adr).to include("`WorkflowContext#merge` remains a non-mutating")
    expect(adr).to include("Direct generated field writers are controlled mutation APIs")
    expect(adr).to include("WorkflowContextOwnershipError")
    expect(adr).to include("write authority and Ruby object immutability are distinct")
  end

  it "keeps the ADR index consistent with the supersession and amendment" do
    index = read("docs/decisions/README.md")

    expect(index).to include(
      "| [`001-rubyllm-as-provider-layer`](001-rubyllm-as-provider-layer.md) | Superseded | No |"
    )
    expect(index).to include(
      "| [`002-workflow-context-immutability`](002-workflow-context-immutability.md) | Amended | Yes |"
    )
    expect(index).to include(
      "| [`027-llm-adapter-provider-boundary`](027-llm-adapter-provider-boundary.md) | Accepted | Yes |"
    )
  end

  it "keeps the new ADR links resolvable" do
    adr = File.join(root, "docs/decisions/027-llm-adapter-provider-boundary.md")
    pattern = /\[[^\]]+\]\(([^)]+)\)/

    File.read(adr).scan(pattern).flatten.each do |target|
      next if target.match?(/\A[a-z][a-z0-9+.-]*:/i)
      next if target.start_with?("#")

      relative_target = target.split("#", 2).first
      next if relative_target.nil? || relative_target.empty?

      resolved = File.expand_path(relative_target, File.dirname(adr))
      expect(File).to exist(resolved), "ADR-027 contains broken relative link #{target.inspect}"
    end
  end
end
