# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::TokenBudgetResolver do
  let(:persistence) { Phronomy::Persistence::InMemory.new }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "manifest-token-budget-test", version: 1
      model "local-model"
      context_window 1_000
      max_output_tokens 100
      context_overhead 200
      instructions "Base instruction"
    end
  end
  let(:agent) { agent_class.new(persistence: persistence) }

  it "does not reserve legacy context_overhead in the Manifest-first budget" do
    budget = described_class.new(agent: agent).resolve(
      "model" => "local-model",
      "context_window" => 1_000,
      "max_output_tokens" => 100
    )

    expect(budget.overhead).to eq(0)
    expect(budget.effective_input_limit).to eq(900)
  end

  it "deducts actual mandatory Manifest content exactly once" do
    selector_class = Class.new do
      attr_reader :token_budget, :mandatory_bytes

      def select(agent_root:, journal_projection:, token_budget:, mandatory_bytes:)
        @token_budget = token_budget
        @mandatory_bytes = mandatory_bytes
        []
      end
    end
    selector = selector_class.new

    root = agent.agent_root
    input_ref = persistence.contents.put_text("hello")
    input_record = Phronomy::Agent::JournalRecord.new(
      agent_id: agent.agent_id, kind: :input_received,
      channel: :external, role: :user, content_ref: input_ref,
      context_generation: root.transcript_generation, context_candidate: false
    )
    execution = Phronomy::Agent::AgentExecution.start(
      agent_root: root, input_record: input_record,
      metadata: {"current_input_ref" => input_ref}
    ).with(execution_revision: 0, working_records: [])

    assembler = Phronomy::Agent::ContextAssembler.new(
      agent: agent, persistence: persistence, selector: selector
    )
    manifest, = assembler.build_initial(
      input: "hello", agent_root: root, execution: execution
    )

    mandatory_estimate =
      Phronomy::LlmContextWindow::TokenEstimator.estimate(selector.mandatory_bytes)
    expected_remaining = [900 - mandatory_estimate, 0].max

    expect(selector.mandatory_bytes).to include("Base instruction")
    expect(selector.mandatory_bytes).to include("hello")
    expect(selector.token_budget.overhead).to eq(0)
    expect(selector.token_budget.available(used: mandatory_estimate)).to eq(expected_remaining)
    expect(manifest.assembly_policy_version).to eq(4)
  end
end
