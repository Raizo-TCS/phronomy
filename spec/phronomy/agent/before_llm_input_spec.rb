# frozen_string_literal: true

require "spec_helper"

class HookBaseAgent < Phronomy::Agent::Base
  agent_definition id: "hook-base-agent", version: 1
  model "test-model"
  instructions "You are a helpful assistant."
end

RSpec.describe "before_llm_input hook" do
  before do
    HookBaseAgent.instance_variable_set(:@before_llm_input, nil)
    Phronomy.configuration.before_llm_input = nil
  end

  after do
    HookBaseAgent.instance_variable_set(:@before_llm_input, nil)
    Phronomy.configuration.before_llm_input = nil
  end

  describe Phronomy::Agent::LLMInputBuildContext do
    let(:agent) { HookBaseAgent.new }
    let(:config) { {thread_id: "t1"} }

    it "exposes agent_id, config, and call_sequence" do
      ctx = described_class.new(
        agent_id: agent.agent_id,
        agent_definition_id: "hook-base-agent",
        agent_definition_version: 1,
        config: config,
        call_sequence: 1
      )
      expect(ctx.agent_id).to eq(agent.agent_id)
      expect(ctx.agent_definition_id).to eq("hook-base-agent")
      expect(ctx.agent_definition_version).to eq(1)
      expect(ctx).not_to respond_to(:definition_version)
      expect(ctx.config).to eq(config)
      expect(ctx.call_sequence).to eq(1)
    end

    it "is frozen (immutable)" do
      ctx = described_class.new(
        agent_id: agent.agent_id,
        agent_definition_id: "hook-base-agent",
        agent_definition_version: 1,
        config: config,
        call_sequence: 2
      )
      expect(ctx).to be_frozen
    end
  end

  describe Phronomy::Agent::LLMInputPatch do
    it ".empty returns a patch with all nil fields" do
      patch = described_class.empty
      expect(patch.model_config_patch).to be_nil
      expect(patch.segment_candidates).to be_nil
    end

    it "accepts model_config_patch" do
      patch = described_class.new(model_config_patch: {temperature: 0.3})
      expect(patch.model_config_patch).to eq({temperature: 0.3})
    end
  end

  describe ".before_llm_input" do
    it "stores and reads a callable" do
      callable = ->(_ctx) { Phronomy::Agent::LLMInputPatch.empty }
      HookBaseAgent.before_llm_input callable
      expect(HookBaseAgent._before_llm_input).to be(callable)
    end

    it "returns nil when not set" do
      expect(HookBaseAgent._before_llm_input).to be_nil
    end

    it "accepts a block" do
      HookBaseAgent.before_llm_input { |_ctx| Phronomy::Agent::LLMInputPatch.empty }
      expect(HookBaseAgent._before_llm_input).to respond_to(:call)
    end

    it "reads back via getter form (no argument)" do
      callable = ->(_ctx) {}
      HookBaseAgent.before_llm_input callable
      expect(HookBaseAgent.before_llm_input).to be(callable)
    end
  end

  describe "#before_llm_input=" do
    it "stores an instance-level callable independent of the class" do
      agent = HookBaseAgent.new
      callable = ->(_ctx) { Phronomy::Agent::LLMInputPatch.empty }
      agent.before_llm_input = callable
      expect(agent.before_llm_input).to be(callable)
      expect(HookBaseAgent._before_llm_input).to be_nil
    end
  end

  describe "#run_before_llm_input_hooks" do
    let(:config) { {thread_id: "t1"} }

    it "returns LLMInputPatch.empty when no hooks are registered" do
      agent = HookBaseAgent.new
      result = agent.send(:run_before_llm_input_hooks, call_sequence: 1, config: config)
      expect(result).to eq(Phronomy::Agent::LLMInputPatch.empty)
    end

    it "calls the global hook with an LLMInputBuildContext" do
      received_ctx = nil
      Phronomy.configuration.before_llm_input = ->(ctx) {
        received_ctx = ctx
        nil
      }
      agent = HookBaseAgent.new
      agent.send(:run_before_llm_input_hooks, call_sequence: 1, config: config)
      expect(received_ctx).to be_a(Phronomy::Agent::LLMInputBuildContext)
      expect(received_ctx.agent_id).to eq(agent.agent_id)
      expect(received_ctx.call_sequence).to eq(1)
      expect(received_ctx.config).to eq(config)
    end

    it "calls the class-level hook" do
      called = false
      HookBaseAgent.before_llm_input ->(_ctx) {
        called = true
        nil
      }
      agent = HookBaseAgent.new
      agent.send(:run_before_llm_input_hooks, call_sequence: 1, config: {})
      expect(called).to be true
    end

    it "calls the instance-level hook" do
      called = false
      agent = HookBaseAgent.new
      agent.before_llm_input = ->(_ctx) {
        called = true
        nil
      }
      agent.send(:run_before_llm_input_hooks, call_sequence: 1, config: {})
      expect(called).to be true
    end

    it "calls hooks in order: global → class → instance" do
      call_order = []
      Phronomy.configuration.before_llm_input = ->(_ctx) {
        call_order << :global
        nil
      }
      HookBaseAgent.before_llm_input ->(_ctx) {
        call_order << :class
        nil
      }
      agent = HookBaseAgent.new
      agent.before_llm_input = ->(_ctx) {
        call_order << :instance
        nil
      }
      agent.send(:run_before_llm_input_hooks, call_sequence: 1, config: {})
      expect(call_order).to eq([:global, :class, :instance])
    end

    it "merges model_config_patch from multiple hooks (later hooks win)" do
      patch_a = Phronomy::Agent::LLMInputPatch.new(
        model_config_patch: {temperature: 0.5, model: "model-a"}
      )
      patch_b = Phronomy::Agent::LLMInputPatch.new(
        model_config_patch: {model: "model-b"}
      )
      Phronomy.configuration.before_llm_input = ->(_ctx) { patch_a }
      agent = HookBaseAgent.new
      agent.before_llm_input = ->(_ctx) { patch_b }
      result = agent.send(:run_before_llm_input_hooks, call_sequence: 1, config: {})
      expect(result.model_config_patch[:temperature]).to eq(0.5)
      expect(result.model_config_patch[:model]).to eq("model-b")
    end

    it "appends segment_candidates from multiple hooks" do
      seg_a = {content: "hello", category: :knowledge, role: :user}
      seg_b = {content: "world", category: :knowledge, role: :user}
      patch_a = Phronomy::Agent::LLMInputPatch.new(segment_candidates: [seg_a])
      patch_b = Phronomy::Agent::LLMInputPatch.new(segment_candidates: [seg_b])
      Phronomy.configuration.before_llm_input = ->(_ctx) { patch_a }
      agent = HookBaseAgent.new
      agent.before_llm_input = ->(_ctx) { patch_b }
      result = agent.send(:run_before_llm_input_hooks, call_sequence: 1, config: {})
      expect(result.segment_candidates).to eq([seg_a, seg_b])
    end

    it "raises TypeError for non-LLMInputPatch return values from hooks" do
      Phronomy.configuration.before_llm_input = ->(_ctx) {}
      HookBaseAgent.before_llm_input ->(_ctx) { "invalid" }
      agent = HookBaseAgent.new
      expect {
        agent.send(:run_before_llm_input_hooks, call_sequence: 1, config: {})
      }.to raise_error(TypeError, /LLMInputPatch/)
    end
  end
end
