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
      instructions "Base instruction"
    end
  end

  let(:agent) { agent_class.new(persistence: persistence) }

  it "resolves the Manifest-first input budget without legacy context_overhead" do
    budget = described_class.new(agent: agent).resolve(
      "model" => "local-model",
      "context_window" => 1_000,
      "max_output_tokens" => 100
    )

    expect(agent_class).not_to respond_to(:context_overhead)
    expect(budget).not_to respond_to(:overhead)
    expect(budget.effective_input_limit).to eq(900)
  end

  it "builds and finally validates the canonical Manifest against the same budget" do
    root = agent.agent_root
    input_ref = persistence.contents.put_text("hello")
    input_record = Phronomy::Agent::JournalRecord.new(
      agent_id: agent.agent_id,
      kind: :external_message,
      channel: :external,
      role: :user,
      content_ref: input_ref,
      context_generation: root.transcript_generation,
      context_candidate: true
    )
    execution = Phronomy::Agent::AgentExecution.start(
      agent_root: root,
      input_record: input_record,
      metadata: {
        "current_input_ref" => input_ref,
        "current_input_record_id" => input_record.record_id
      }
    ).with(
      execution_revision: 0,
      working_records: [input_record]
    )

    manifest, = Phronomy::Agent::ContextAssembler.new(
      agent: agent,
      persistence: persistence
    ).build_initial(
      input: "hello",
      agent_root: root,
      execution: execution
    )

    expect(manifest.assembly_policy_version)
      .to eq(Phronomy::Agent::ContextAssembler::ASSEMBLY_POLICY_VERSION)
    expect(manifest.segments.map(&:category))
      .to include(:instruction, :current_input)
    expect(manifest.segments.count { |segment|
      segment.delivery == :ask_argument
    }).to eq(1)
  end

  it "does not charge Provider configuration metadata as prompt tokens" do
    root = agent.agent_root
    input_ref = persistence.contents.put_text("hello")
    input_record = Phronomy::Agent::JournalRecord.new(
      agent_id: agent.agent_id,
      kind: :external_message,
      channel: :external,
      role: :user,
      content_ref: input_ref,
      context_generation: root.transcript_generation,
      context_candidate: true
    )
    execution = Phronomy::Agent::AgentExecution.start(
      agent_root: root,
      input_record: input_record,
      metadata: {
        "current_input_ref" => input_ref,
        "current_input_record_id" => input_record.record_id
      }
    ).with(
      execution_revision: 0,
      working_records: [input_record]
    )

    manifest, = Phronomy::Agent::ContextAssembler.new(
      agent: agent,
      persistence: persistence
    ).build_initial(
      input: "hello",
      agent_root: root,
      execution: execution,
      config: {}
    )

    model_config = persistence.contents.fetch_json(manifest.model_config_ref)
    # Provider metadata keys (model, temperature, etc.) are stored in
    # model_config and are not counted as context segments or prompt tokens.
    expect(model_config).to have_key("model")
    expect(model_config).not_to have_key("thread_id")
  end
end
