# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Group 26: Multi-Agent Handoff
# Pairwise factors: handoff_topology × handoff_trigger × handoff_context_persistence × handoff_agent_count
# Generated stubs: 10 cases
#
# Infeasible cases (SKIP):
#   TC-002: single_agent × handoff_once — no handoff tool registered; trigger impossible
#   TC-003: single_agent × three agents — single_agent topology contradicts multiple agents in routes
#   TC-006: linear × one agent — linear topology requires ≥2 agents
#   TC-007: hub_spoke × one agent — hub_spoke topology requires ≥3 agents
#   TC-008: hub_spoke × handoff_once × one agent — same reason as TC-007
#
# LLM required: No (WebMock)

RSpec.describe "Group 26: Multi-Agent Handoff", :integration do
  before do
    @llm = LLMStub.activate(responses: ["Hello from entry agent."])
  end

  after { LLMStub.deactivate }

  # ---------------------------------------------------------------------------
  # TC-001: single_agent / no_handoff / fresh / one
  #         Runner wraps one agent; no handoff; returns entry agent result.
  # ---------------------------------------------------------------------------
  describe "TC-001: single_agent; no_handoff; fresh; one agent" do
    it "runner returns entry agent output without handoff" do
      klass = Class.new(Phronomy::Agent::Base) do
        model IntegrationFactors::LM_MODEL_26
        provider :openai
        instructions "You are a helpful assistant."
      end
      agent = klass.new
      runner = Phronomy::Agent::Runner.new(agents: [agent])
      result = runner.invoke("Hello")
      expect(result[:output]).to be_a(String)
      expect(result[:agent]).to equal(agent)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: single_agent / handoff_once / shared_thread / two  — INFEASIBLE
  # ---------------------------------------------------------------------------
  # SKIP: single_agent topology registers no handoff tools;
  #       handoff_once cannot trigger without a transfer tool registered on the agent.

  # ---------------------------------------------------------------------------
  # TC-003: single_agent / no_handoff / shared_thread / three — INFEASIBLE
  # ---------------------------------------------------------------------------
  # SKIP: single_agent topology contradicts having three agents;
  #       three agents are only meaningful when routing is configured.

  # ---------------------------------------------------------------------------
  # TC-004: linear / no_handoff / fresh / two
  #         Two agents; handoff tool registered but LLM does not call it.
  # ---------------------------------------------------------------------------
  describe "TC-004: linear; no_handoff; fresh; two agents" do
    it "runner returns entry agent output when handoff tool not called" do
      entry_klass, target_klass = IntegrationFactors.handoff_linear_classes
      entry = entry_klass.new
      target = target_klass.new
      runner = Phronomy::Agent::Runner.new(
        agents: [entry, target],
        routes: {entry => [target]}
      )
      result = runner.invoke("Tell me something.")
      expect(result[:output]).to be_a(String)
      expect(result[:agent]).to equal(entry)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-005: linear / handoff_once / fresh / three
  #         Entry agent calls transfer tool; Runner routes to second agent.
  # ---------------------------------------------------------------------------
  describe "TC-005: linear; handoff_once; fresh; entry hands off to target" do
    it "runner routes to second agent after handoff tool call" do
      entry_klass, target_klass = IntegrationFactors.handoff_linear_classes
      entry = entry_klass.new
      target = target_klass.new

      runner = Phronomy::Agent::Runner.new(
        agents: [entry, target],
        routes: {entry => [target]}
      )

      # Capture the tool_name the handoff tool will use.
      handoff_tool_name = "transfer_to_#{target_klass.name&.split("::")&.last&.gsub(/([A-Z])/) { "_#{$1}" }&.downcase&.delete_prefix("_") || "agent"}"
      LLMStub.deactivate
      @llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response(handoff_tool_name, {}),
        "Routing you to the billing assistant.",
        "I can help with your billing question."
      ])

      result = runner.invoke("I have a billing issue.")
      expect(result[:output]).to be_a(String)
      expect(result[:agent]).to equal(target)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: linear / no_handoff / shared_thread / one — INFEASIBLE
  # ---------------------------------------------------------------------------
  # SKIP: linear topology requires ≥2 agents; one agent contradicts linear routing setup.

  # ---------------------------------------------------------------------------
  # TC-007: hub_spoke / no_handoff / fresh / one — INFEASIBLE
  # ---------------------------------------------------------------------------
  # SKIP: hub_spoke topology requires ≥3 agents; one agent contradicts hub_spoke setup.

  # ---------------------------------------------------------------------------
  # TC-008: hub_spoke / handoff_once / shared_thread / one — INFEASIBLE
  # ---------------------------------------------------------------------------
  # SKIP: hub_spoke topology requires ≥3 agents; one agent contradicts hub_spoke setup.

  # ---------------------------------------------------------------------------
  # TC-009: hub_spoke / no_handoff / fresh / two
  #         Hub + 1 spoke; no handoff triggered; runner returns hub result.
  # ---------------------------------------------------------------------------
  describe "TC-009: hub_spoke; no_handoff; fresh; two agents (hub + 1 spoke)" do
    it "runner returns hub output when no handoff triggered" do
      hub, spoke1 = IntegrationFactors.handoff_hub_spoke_instances(spoke_count: 1)
      runner = Phronomy::Agent::Runner.new(
        agents: [hub, spoke1],
        routes: {hub => [spoke1]}
      )
      result = runner.invoke("Hello from hub test.")
      expect(result[:output]).to be_a(String)
      expect(result[:agent]).to equal(hub)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-010: hub_spoke / no_handoff / fresh / three
  #         Hub + 2 spokes; no handoff triggered; runner returns hub result.
  # ---------------------------------------------------------------------------
  describe "TC-010: hub_spoke; no_handoff; fresh; three agents (hub + 2 spokes)" do
    it "runner returns hub output when no handoff triggered" do
      hub, spoke1, spoke2 = IntegrationFactors.handoff_hub_spoke_instances(spoke_count: 2)
      runner = Phronomy::Agent::Runner.new(
        agents: [hub, spoke1, spoke2],
        routes: {hub => [spoke1, spoke2]}
      )
      result = runner.invoke("Hello from hub-spoke test.")
      expect(result[:output]).to be_a(String)
      expect(result[:agent]).to equal(hub)
    end
  end
end
