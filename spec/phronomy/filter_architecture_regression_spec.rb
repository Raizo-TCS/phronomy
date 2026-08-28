# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Filter architecture regression contract (ACS-03)" do
  let(:root) { File.expand_path("../..", __dir__) }

  it "keeps the removed Guardrail runtime contracts absent" do
    expect(Phronomy.const_defined?(:Guardrail, false)).to be(false)
    expect(Phronomy.const_defined?(:GuardrailError, false)).to be(false)

    legacy_class_methods = Phronomy::Agent::Base.public_methods(false).grep(/guardrail/)
    legacy_instance_methods = Phronomy::Agent::Base.public_instance_methods.grep(/guardrail/)

    expect(legacy_class_methods).to be_empty
    expect(legacy_instance_methods).to be_empty
  end

  it "keeps current Filter behavior as transform-or-block with explicit call sites" do
    source = File.read(File.join(root, "lib/phronomy/filter/base.rb"))

    expect(source).to include("transform a value")
    expect(source).to include("raise {Phronomy::FilterBlockError}")
    expect(source).to include("input, output, and tool result")

    filter = Class.new(Phronomy::Filter::Base) do
      def call(value, **_context)
        return value.to_s.upcase unless value == :reject

        block!("rejected")
      end
    end.new

    expect(filter.call("ok")).to eq("OK")
    expect { filter.call(:reject) }
      .to raise_error(Phronomy::FilterBlockError, "rejected")
  end

  it "keeps PromptInjectionFilter a current bounded Filter rather than legacy Guardrail API" do
    expect(Phronomy::Filter::PromptInjectionFilter)
      .to be < Phronomy::Filter::Base

    adr = File.read(
      File.join(root, "docs/decisions/019-filter-contract-and-security-boundaries.md")
    )
    expect(adr).to include("bounded heuristic baseline")
    expect(adr).to include("does **not** automatically inspect every value")
    expect(adr).to include("does not decide whether Phronomy should add a dedicated")
  end

  it "makes ADR-019 normative and ADR-006 historical" do
    adr006 = File.read(
      File.join(root, "docs/decisions/006-no-built-in-guardrails.md")
    )
    adr019 = File.read(
      File.join(root, "docs/decisions/019-filter-contract-and-security-boundaries.md")
    )
    index = File.read(File.join(root, "docs/decisions/README.md"))

    expect(adr006).to include("Superseded by")
    expect(adr006).to include("019-filter-contract-and-security-boundaries.md")
    expect(adr019).to include("## Status\n\nAccepted.")
    expect(adr019).to include("This ADR supersedes ADR-006")
    expect(index).to match(
      /\[`006-no-built-in-guardrails`\].*\| Superseded \| No \|/
    )
    expect(index).to match(
      /\[`019-filter-contract-and-security-boundaries`\].*\| Accepted \| Yes \|/
    )
  end

  it "keeps the old Guardrail design only in the non-normative archive" do
    legacy_path = File.join(root, "docs/archive/design/archived/09_guardrails.md")
    expect(File).to exist(legacy_path)
    expect(File).not_to exist(File.join(root, "spec/design/09_guardrails.md"))

    legacy = File.read(legacy_path)
    expect(legacy).to start_with("> **ARCHIVED / non-normative**")
  end

  it "keeps active spec filenames and current feature catalog free of legacy Guardrail naming" do
    legacy_spec_names = Dir.glob(
      File.join(root, "spec/{phronomy,integration}/**/*guardrail*.rb")
    )
    expect(legacy_spec_names).to be_empty

    # Scope is the ACS-03 terminology-cleaned active specs only.
    # Historical ADR/design files retain Guardrail wording as decision evidence.
    terminology_files = %w[
      spec/phronomy/filter_blocking_spec.rb
      spec/phronomy/security_spec.rb
      spec/phronomy/fault_injection_extended_spec.rb
      spec/phronomy/fault_injection_advanced_spec.rb
      spec/integration/tool_filter_spec.rb
      spec/integration/support/factors.rb
      spec/integration/streaming_spec.rb
    ]
    terminology_files.each do |relative_path|
      expect(File.read(File.join(root, relative_path))).not_to match(/guardrail/i)
    end

    features = File.read(File.join(root, "docs/features.md"))
    expect(features).not_to match(/\bguardrails?\b/i)
    expect(features).to include(
      "**Filters** — Input/output transformation and blocking via `Filter::Base`"
    )
  end

  it "keeps raw input filtering explicit and closes Context inspection through ContextPolicy" do
    coordinator = File.read(
      File.join(root, "lib/phronomy/agent/execution_coordinator.rb")
    )
    security = File.read(
      File.join(root, "docs/architecture/security-boundaries.md")
    )

    expect(coordinator).to include("run_input_filters!")
    expect(security).to include(
      "does **not** add a fourth `context_filter`"
    )
    expect(security).to include(
      "Application-defined `ContextPolicy` owns semantic trust decisions"
    )
  end
end
