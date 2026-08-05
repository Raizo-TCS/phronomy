# frozen_string_literal: true

require "spec_helper"

RSpec.describe "stateful manifest follow-up regressions" do
  it "rejects an invalid before_llm_input return value" do
    klass = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "invalid-hook-result", version: 1
      before_llm_input ->(_context) { {} }
    end
    expect {
      klass.new.send(:run_before_llm_input_hooks, call_sequence: 1, config: {})
    }.to raise_error(TypeError, /LLMInputPatch/)
  end

  it "deep-copies hook config" do
    config = {nested: {value: 1}}
    context = Phronomy::Agent::LLMInputBuildContext.new(
      agent_id: "a", agent_definition_id: "d", definition_version: 1,
      config: config, call_sequence: 1
    )
    config[:nested][:value] = 2
    expect(context.config[:nested][:value]).to eq(1)
  end

  it "requires a valid output reserve for an explicit context window" do
    agent = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "budget-agent", version: 1
    end.new
    expect {
      Phronomy::Agent::TokenBudgetResolver.new(agent: agent).resolve(
        "model" => "local", "context_window" => 1024
      )
    }.to raise_error(Phronomy::InvalidContextBudgetConfigurationError)
  end

  describe "build_followup model config base" do
    let(:persistence) { Phronomy::Persistence::InMemory.new }
    let(:agent_class) do
      Class.new(Phronomy::Agent::Base) do
        agent_definition id: "followup-model-test", version: 1
        model "base-model"
      end
    end
    let(:agent) { agent_class.new(persistence: persistence) }

    def build_test_manifest(model_name)
      model_cfg = {"model" => model_name}
      model_ref = persistence.contents.put_json(model_cfg)
      tool_ref  = persistence.contents.put_json([])
      Phronomy::Agent::LLMInputManifest.new(
        call_sequence: 1, call_mode: :complete,
        segments: [], model_config_ref: model_ref,
        tool_definitions_ref: tool_ref,
        assembly_policy_version: 2, ruby_llm_version: nil, adapter_name: "test"
      )
    end

    def resolve_model_from_manifest(manifest)
      JSON.parse(persistence.contents.fetch_text(manifest.model_config_ref))["model"]
    end

    it "applies each follow-up patch to the agent base config, not the initial Manifest" do
      root = agent.instance_variable_get(:@root)
      execution = Phronomy::Agent::AgentExecution.start(
        agent_root: root,
        input_record: Phronomy::Agent::JournalRecord.new(
          agent_id: agent.agent_id, kind: :input_received,
          channel: :external, role: :user,
          content_ref: persistence.contents.put_text("hi"),
          context_generation: root.transcript_generation, context_candidate: false
        ),
        metadata: {}
      ).with(execution_revision: 0, working_records: [])
      base_manifest = build_test_manifest("call-one-model")

      assembler = Phronomy::Agent::ContextAssembler.new(agent: agent, persistence: persistence)
      result_manifest, _ref = assembler.build_followup(
        base_manifest: base_manifest, agent_root: root, execution: execution, config: {}
      )
      expect(resolve_model_from_manifest(result_manifest)).to eq("base-model")
    end

    it "applies the current follow-up patch on top of agent base config" do
      root = agent.instance_variable_get(:@root)
      execution = Phronomy::Agent::AgentExecution.start(
        agent_root: root,
        input_record: Phronomy::Agent::JournalRecord.new(
          agent_id: agent.agent_id, kind: :input_received,
          channel: :external, role: :user,
          content_ref: persistence.contents.put_text("hi"),
          context_generation: root.transcript_generation, context_candidate: false
        ),
        metadata: {}
      ).with(execution_revision: 0, working_records: [])
      base_manifest = build_test_manifest("call-one-model")

      patch = Phronomy::Agent::LLMInputPatch.new(model_config_patch: {model: "call-two-model"})
      assembler = Phronomy::Agent::ContextAssembler.new(agent: agent, persistence: persistence)
      result_manifest, _ref = assembler.build_followup(
        base_manifest: base_manifest, agent_root: root, execution: execution,
        config: {}, patch: patch
      )
      expect(resolve_model_from_manifest(result_manifest)).to eq("call-two-model")
    end
  end
end
