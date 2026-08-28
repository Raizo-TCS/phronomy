# frozen_string_literal: true

require "spec_helper"

RSpec.describe "ACS-02 architecture documentation lifecycle" do
  let(:root) { File.expand_path("../..", __dir__) }

  let(:current_docs) do
    %w[
      docs/architecture.md
      docs/architecture/agent-context.md
      docs/architecture/context-management.md
      docs/architecture/knowledge-and-rag.md
      docs/architecture/security-boundaries.md
      docs/architecture/tracing.md
      docs/architecture/multi-agent-handoff.md
      docs/architecture/persistence.md
      docs/architecture/before-llm-input.md
      docs/architecture/removed/agent-context.md
    ]
  end

  it "keeps one canonical architecture entry and removes the legacy spec/design tree" do
    current_docs.each { |path| expect(File).to exist(File.join(root, path)) }
    expect(Dir.glob(File.join(root, "spec/design/**/*"), File::FNM_DOTMATCH)).to eq([])
  end

  it "separates CURRENT from HISTORICAL and ARCHIVED design material" do
    current_docs.drop(1).each do |path|
      expect(File.read(File.join(root, path))).to match(
        /\A> \*\*(CURRENT explanatory architecture|CURRENT negative architecture guidance)\*\*/
      )
    end

    %w[
      docs/archive/design/historical/00_design_philosophy.md
      docs/archive/design/historical/01_rubyllm_evaluation.md
      docs/archive/design/historical/06_design_decisions.md
    ].each do |path|
      expect(File.read(File.join(root, path)))
        .to start_with("> **HISTORICAL / non-normative snapshot**")
    end

    %w[
      docs/archive/design/archived/04_api_design.md
      docs/archive/design/archived/09_guardrails.md
      docs/archive/design/archived/17_rails_integration.md
    ].each do |path|
      expect(File.read(File.join(root, path)))
        .to start_with("> **ARCHIVED / non-normative**")
    end
  end

  it "keeps reconciled F01-F04 boundaries in current docs" do
    context = File.read(File.join(root, "docs/architecture/context-management.md"))
    security = File.read(File.join(root, "docs/architecture/security-boundaries.md"))
    tracing = File.read(File.join(root, "docs/architecture/tracing.md"))
    handoff = File.read(File.join(root, "docs/architecture/multi-agent-handoff.md"))

    expect(context).to include("instruction / knowledge / tools / conversation")
    expect(context).to include("ContextPolicy is **not** one of the Framework's standard automatic tracing span")
    expect(security).to include("does **not** add a fourth `context_filter`")
    expect(security).to include("Tool approval is authorization, not sanitization")

    %w[agent.execution workflow.execution llm.call tool.execute multi_agent.turn].each do |name|
      expect(tracing).to include(name)
    end
    expect(tracing).to include("does not define a custom `TraceContext`")
    expect(tracing).not_to include("Every LLM call made by a Chain")

    expect(handoff).to include("not durably rehydrated")
    expect(handoff).to include("Source execution identity")
  end

  it "keeps Persistence on current identity, codec, and Recovery vocabulary" do
    persistence = File.read(File.join(root, "docs/architecture/persistence.md"))

    expect(persistence).to include("workflow_instance_id")
    expect(persistence).to include("DurableRecord")
    expect(persistence).to include("format_version")
    expect(persistence).to include("resumable")
    expect(persistence).to include("reconcilable")
    expect(persistence).to include("resolution_required")
    expect(persistence).not_to match(/durable Workflow identity.*thread_id/i)
  end

  it "keeps relative links in CURRENT architecture documents resolvable" do
    pattern = /\[[^\]]+\]\(([^)]+)\)/

    current_docs.each do |relative_path|
      path = File.join(root, relative_path)
      File.read(path).scan(pattern).flatten.each do |target|
        next if target.match?(/\A[a-z][a-z0-9+.-]*:/i)
        next if target.start_with?("#")

        relative_target = target.split("#", 2).first
        next if relative_target.nil? || relative_target.empty?

        resolved = File.expand_path(relative_target, File.dirname(path))
        expect(File).to exist(resolved),
          "#{relative_path} contains broken relative link #{target.inspect}"
      end
    end
  end
end
