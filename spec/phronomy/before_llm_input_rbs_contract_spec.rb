# frozen_string_literal: true

require "spec_helper"

RSpec.describe "before_llm_input Stable RBS contract (ACS-07)" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:agent_rbs) { File.read(File.join(root, "sig/phronomy/agent.rbs")) }
  let(:top_rbs) { File.read(File.join(root, "sig/phronomy.rbs")) }

  it "keeps the three Stable registration tiers represented in runtime and RBS" do
    expect(Phronomy.configuration).to respond_to(
      :before_llm_input,
      :before_llm_input=
    )
    expect(Phronomy::Agent::Base).to respond_to(:before_llm_input)
    expect(Phronomy::Agent::Base.public_instance_methods).to include(
      :before_llm_input,
      :before_llm_input=
    )

    expect(top_rbs).to match(
      /attr_accessor\s+before_llm_input:\s+Agent::_BeforeLLMInputHook\?/
    )
    expect(agent_rbs).to match(
      /def self\.before_llm_input:.*_BeforeLLMInputHook/m
    )
    expect(agent_rbs).to match(
      /attr_accessor\s+before_llm_input:\s+_BeforeLLMInputHook\?/
    )
  end

  it "represents the current LLMInputPatch capability without inventing future fields" do
    expect(Phronomy::Agent::LLMInputPatch.members).to eq(
      %i[model_config_patch segment_candidates]
    )

    expect(agent_rbs).to include("class LLMInputPatch")
    expect(agent_rbs).to match(
      /attr_reader\s+model_config_patch:\s+Hash\[untyped,\s*untyped\]\?/
    )
    expect(agent_rbs).to match(
      /attr_reader\s+segment_candidates:\s+Array\[untyped\]\?/
    )
    expect(agent_rbs).to include("def self.empty: () -> LLMInputPatch")

    # Baseline D02-18-6/D02-18-20: do not turn previously discussed future
    # shapes into a Stable contract merely by placing them in RBS.
    expect(agent_rbs).not_to include("response_schema_candidate")
    expect(agent_rbs).not_to include("selection_policy_override")
    expect(agent_rbs).not_to include("LLMInputDraft")
  end

  it "represents exactly the current immutable metadata-only build context" do
    expect(Phronomy::Agent::LLMInputBuildContext.members).to eq(
      %i[
        agent_id
        agent_definition_id
        agent_definition_version
        config
        call_sequence
      ]
    )

    # Scope RBS checks to LLMInputBuildContext itself. In particular,
    # Agent::Base also has an agent_id reader, so whole-file matching could
    # otherwise hide an accidental loss of LLMInputBuildContext#agent_id.
    build_context_section = agent_rbs
      .split("class LLMInputBuildContext", 2)
      .fetch(1)
      .split(/^\s*end\b/, 2)
      .first

    %w[
      agent_id
      agent_definition_id
      agent_definition_version
      config
      call_sequence
    ].each do |reader|
      expect(build_context_section).to match(
        /attr_reader\s+#{Regexp.escape(reader)}:/
      )
    end

    # Baseline D02-18-4: live mutable/runtime objects are not the hook surface.
    expect(Phronomy::Agent::LLMInputBuildContext.members).not_to include(
      :agent,
      :chat,
      :persistence,
      :event_loop
    )
    expect(build_context_section).not_to match(/attr_reader\s+agent:/)
    expect(build_context_section).not_to match(/attr_reader\s+chat:/)
    expect(build_context_section).not_to match(/attr_reader\s+persistence:/)
    expect(build_context_section).not_to match(/attr_reader\s+event_loop:/)
  end

  it "types hook results as LLMInputPatch or nil rather than broad untyped output" do
    expect(agent_rbs).to match(
      /interface _BeforeLLMInputHook.*def call:\s+\(LLMInputBuildContext context\)\s+->\s+LLMInputPatch\?/m
    )
  end

  it "does not encode current Persistence transaction placement as API contract" do
    hook_contract = agent_rbs
      .split("interface _BeforeLLMInputHook", 2)
      .fetch(1)
      .split("class LLMInputPatch", 2)
      .first

    expect(hook_contract).not_to match(
      /\btransaction\b|\bPersistence\b|\bEventLoop\b|\bOffloadPool\b/
    )
  end
end
