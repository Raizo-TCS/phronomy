# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Durability guarantee and failure-model architecture contract (ACS-18)" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:adr_path) {
    File.join(
      root,
      "docs/decisions/018-durability-guarantees-and-failure-model.md"
    )
  }
  let(:adr) { File.read(adr_path) }

  GUARANTEES = [
    "durable state persistence",
    "durable-state restart readability",
    "logical-state rehydration",
    "execution resumption",
    "durable-transition atomicity",
    "same-process competing-execution exclusion",
    "cross-process competing-execution exclusion",
    "stale durable-transition conflict detection",
    "duplicate external-side-effect prevention",
    "exactly-once external-side-effect execution"
  ].freeze

  FAILURE_LABELS = {
    "F0" => "Operation Failure",
    "F1" => "Outcome Uncertainty",
    "F2" => "Concurrency Conflict",
    "F3" => "Asynchronous Lifecycle Mismatch",
    "F4" => "Execution-Environment Loss",
    "X0" => "External Effect Boundary"
  }.freeze

  it "defines all ten D05 guarantees as distinct canonical vocabulary" do
    GUARANTEES.each do |guarantee|
      expect(adr).to include(guarantee)
    end

    expect(adr).to include("Guarantee terms are not an implication hierarchy")
    expect(adr).to include(
      "durable-transition atomicity\n    != commit outcome certainty"
    )
    expect(adr).to include(
      "same-process competing-execution exclusion\n    != cross-process competing-execution exclusion"
    )
  end

  it "defines F0-F4 as failure classes and X0 as a separate boundary" do
    FAILURE_LABELS.each do |identifier, label|
      expect(adr).to include("#{identifier} — #{label}")
    end

    expect(adr).to include(
      "`F0` through `F4` are identifiers, not a severity scale"
    )
    expect(adr).to include("`X0` is **not a failure class**")
    expect(adr).to include(
      "F0 and F1 describe different dimensions and may apply to the same scenario."
    )
    expect(adr).to include(
      "F1 may simultaneously apply when the underlying durable or"
    )
  end

  it "keeps rehydration separate from execution resumption" do
    expect(adr).to include(
      "Rehydration does not restore the pre-crash object graph and does not itself\nimply execution resumption."
    )
    expect(adr).to include(
      "`logical-state rehydration = YES` never means unconditional automatic resume."
    )
  end

  it "keeps cross-process exclusion conditional and external exactly-once negative" do
    expect(adr).to match(
      /Cross-process competing-execution exclusion \| \*\*CONDITIONAL\*\* \| \*\*CONDITIONAL\*\*/
    )
    expect(adr).to include(
      "Arbitrary external-effect duplicate prevention | **CONDITIONAL**"
    )
    expect(adr).to include(
      "Arbitrary external-effect exactly-once execution | **NO**"
    )
  end

  it "does not turn the architecture taxonomy into a public type hierarchy" do
    expect(Phronomy.const_defined?(:FailureClass, false)).to be(false)
    expect(Phronomy.const_defined?(:GuaranteeLevel, false)).to be(false)

    expect(adr).to include(
      "does **not** add a\npublic `FailureClass` enum"
    )
  end

  it "requires contributors to name guarantees and failure boundaries precisely" do
    contributing = File.read(File.join(root, "CONTRIBUTING.md"))

    expect(contributing).to include(
      "018-durability-guarantees-and-failure-model"
    )
    expect(contributing).to include(
      "F0 operation failure and F1 outcome uncertainty are distinct dimensions"
    )
    expect(contributing).to include(
      "may co-occur; an F0 result does not prove durable/external outcome certainty"
    )
    expect(contributing).to include(
      "optimistic conflict detection is not cross-process execution exclusion"
    )
    expect(contributing).to include(
      "arbitrary external exactly-once execution is not an unconditional Phronomy"
    )
  end

  it "keeps the Persistence transaction contract explicit about F1/ exactly-once limits" do
    persistence = File.read(File.join(root, "lib/phronomy/persistence.rb"))

    expect(persistence).to match(
      /commit outcome is fundamentally.*Phronomy does not claim.*exactly-once semantics/m
    )
    expect(persistence).to match(
      /does not\s+#\s+mean cross-process Workflow admission or distributed locking/m
    )
  end
end
