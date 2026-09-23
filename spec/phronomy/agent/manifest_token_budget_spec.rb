# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::TokenBudgetResolver do
  before do
    allow(RubyLLM.models).to receive(:find).and_call_original
    allow(RubyLLM.models).to receive(:find).with("local-model", provider: nil)
      .and_return(double("RubyLLM model", context_window: 1_000))
  end

  let(:persistence) { Phronomy::Persistence.in_memory }

  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "manifest-token-budget-test", version: 1
      model "local-model"

      max_output_tokens 100
      instructions "Base instruction"
    end
  end

  let(:agent) { agent_class.new(persistence: persistence) }

  it "resolves the Manifest-first input budget without legacy context_overhead" do
    budget = described_class.new.resolve(
      "model" => "local-model",
      "max_output_tokens" => 100
    )

    expect(agent_class).not_to respond_to(:context_overhead)
    expect(budget).not_to respond_to(:overhead)
    expect(budget.effective_input_limit).to eq(1_000)
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

    assembler = Phronomy::Agent::ContextAssembler.new(
      agent: agent,
      persistence: persistence
    )
    prepared = assembler.prepare_initial(
      input: "hello",
      agent_root: root,
      execution: execution
    )
    manifest, = assembler.finalize(prepared)

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

    assembler = Phronomy::Agent::ContextAssembler.new(
      agent: agent,
      persistence: persistence
    )
    prepared = assembler.prepare_initial(
      input: "hello",
      agent_root: root,
      execution: execution,
      config: {}
    )
    manifest, = assembler.finalize(prepared)

    model_config = persistence.contents.fetch_json(manifest.model_config_ref)
    # Provider metadata keys (model, temperature, etc.) are stored in
    # model_config and are not counted as context segments or prompt tokens.
    expect(model_config).to have_key("model")
    expect(model_config).not_to have_key("thread_id")
    expect(model_config).not_to have_key("context_window")
    expect(model_config["max_output_tokens"]).to eq(100)
  end
  it "does not reserve output capacity or store input capabilities in model_config" do
    agent_class.max_output_tokens 50_000
    budget = described_class.new.resolve("model" => "local-model", "max_output_tokens" => 50_000)
    expect(budget.effective_input_limit).to eq(1_000)
    expect(Phronomy.configuration).not_to respond_to(:default_output_reserve)
    expect(agent_class).not_to respond_to(:context_window)
  end

  it "qualifies registry lookup by provider when model IDs overlap" do
    expect(RubyLLM.models).to receive(:find).with("shared", provider: "anthropic")
      .and_return(double(context_window: 1234))
    budget = described_class.new.resolve("model" => "shared", "provider" => "anthropic")
    expect(budget.max_input_tokens).to eq(1234)
  end

  [nil, 0, -1, "1000"].each do |limit|
    it "leaves hard budgeting unset for unavailable or invalid registry input metadata #{limit.inspect}" do
      allow(RubyLLM.models).to receive(:find).with("local-model", provider: nil)
        .and_return(double(context_window: limit))
      expect(described_class.new.resolve("model" => "local-model", "max_output_tokens" => 100)).to be_nil
    end
  end

  it "leaves hard budgeting unset for unknown models" do
    expect(described_class.new.resolve("model" => "not-a-registered-model")).to be_nil
  end
end
