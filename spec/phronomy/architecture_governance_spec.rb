# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Architecture governance" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:decisions_dir) { File.join(root, "docs/decisions") }
  let(:index) { File.read(File.join(decisions_dir, "README.md")) }
  let(:decision_files) {
    Dir.glob(File.join(decisions_dir, "[0-9][0-9][0-9]-*.md")).sort
  }

  it "indexes every numbered ADR by its canonical filename key" do
    decision_files.each do |path|
      filename = File.basename(path)
      key = File.basename(path, ".md")

      expect(index).to include("[`#{key}`](#{filename})"),
        "docs/decisions/README.md does not index #{filename}"
    end
  end

  it "allows only the documented legacy duplicate numeric prefix 011" do
    grouped = decision_files.group_by { |path| File.basename(path)[0, 3] }
    duplicates = grouped.select { |_prefix, paths| paths.length > 1 }

    expect(duplicates.keys).to eq(["011"])
    expect(duplicates.fetch("011").map { |path| File.basename(path) })
      .to contain_exactly(
        "011-build-context-as-single-llm-input-authority.md",
        "011-delegate-transport-policy-to-adapters.md"
      )

    expect(index).to include("Legacy duplicate `011`")
    expect(index).to include("MUST NOT be silently renumbered")
  end

  it "keeps legacy supersession relationships unambiguous in the ADR index" do
    expected = {
      "004-invoke-timeout-is-not-cancellation.md" =>
        "011-delegate-transport-policy-to-adapters.md",
      "005-static-knowledge-class-level-cache.md" =>
        "013-journal-backed-knowledge-as-context-candidates.md",
      "008-orchestrator-uses-os-threads.md" =>
        "010-cooperative-first-concurrency.md",
      "009-state-store-abstraction.md" =>
        "014-unified-persistence-durable-state.md",
      "011-build-context-as-single-llm-input-authority.md" =>
        "012-canonical-execution-log-and-context-policy.md"
    }

    expected.each do |old_filename, replacement_filename|
      old_key = File.basename(old_filename, ".md")
      replacement_key = File.basename(replacement_filename, ".md")

      expect(index).to match(
        /\[`#{Regexp.escape(old_key)}`\]\(#{Regexp.escape(old_filename)}\).*Superseded.*\[`#{Regexp.escape(replacement_key)}`\]\(#{Regexp.escape(replacement_filename)}\)/
      )
    end
  end

  it "makes ADR-017 the normative repository Design Authority decision" do
    adr_path = File.join(
      decisions_dir,
      "017-design-authority-and-adr-governance.md"
    )
    adr = File.read(adr_path)

    expect(adr).to include("## Status")
    expect(adr).to match(/## Status\s+Accepted\./m)
    expect(adr).to include("does **not** define one universal precedence order")
    expect(adr).to include("Accepted and non-superseded ADRs")
    expect(adr).to include("Source code and runtime behavior")
    expect(adr).to include("RBS represents a contract that already exists")
    expect(adr).to include("architecture inconsistency")
    expect(adr).to include("canonical key for an ADR is its filename basename")
  end

  it "documents the same authority boundary for contributors" do
    contributing = File.read(File.join(root, "CONTRIBUTING.md"))

    expect(contributing).to include(
      "017-design-authority-and-adr-governance"
    )
    expect(contributing).to include("docs/decisions/README.md")
    expect(contributing).to include("no universal artifact priority")
    expect(contributing).to include("RBS does not create a contract")
    expect(contributing).to include("architecture inconsistency")
  end
end
