# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Manifest-first Context Management integration smoke coverage.
#
# Selection details and dependency atomicity belong to unit-level Context Policy
# specs. These integration cases verify that the public Agent path actually
# reaches the canonical Journal -> Context Policy -> Manifest pipeline.

RSpec.describe "Group: Context Management", :integration do
  before do
    @llm = LLMStub.activate(
      responses: ["first", "second", "knowledge", "patched"]
    )
  end

  after { LLMStub.deactivate }

  it "persists canonical Agent history across consecutive invocations" do
    agent = IntegrationFactors.context_agent.new

    before_position = agent.agent_root.journal_position
    first = agent.invoke("first message")
    middle_position = agent.agent_root.journal_position
    second = agent.invoke("second message")
    after_position = agent.agent_root.journal_position

    expect(first[:output]).to be_a(String)
    expect(second[:output]).to be_a(String)
    expect(middle_position).to be > before_position
    expect(after_position).to be > middle_position
  end

  it "keeps persistent Knowledge on the Manifest-first Context Policy path" do
    agent = IntegrationFactors.context_agent.new(
      knowledge: IntegrationFactors.knowledge("multi")
    )

    result = agent.invoke("Use the configured knowledge.")
    expect(result[:output]).to be_a(String)
    expect(result[:output]).not_to be_empty
  end

  it "allows before_llm_input to add a per-call logical Context candidate" do
    klass = IntegrationFactors.context_agent
    klass.before_llm_input ->(_ctx) {
      Phronomy::Agent::LLMInputPatch.new(
        segment_candidates: [
          {
            content: "application supplied context",
            category: :knowledge,
            role: :user
          }
        ]
      )
    }

    result = klass.new.invoke("Use the patched context.")
    expect(result[:output]).to be_a(String)
  end

  it "does not expose the removed build_context extension contract" do
    agent = IntegrationFactors.context_agent.new
    expect(agent.respond_to?(:build_context, true)).to be(false)
  end
end
