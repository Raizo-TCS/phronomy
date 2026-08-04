# frozen_string_literal: true

require "spec_helper"

# ---------------------------------------------------------------------------
# Fixture agent classes
# ---------------------------------------------------------------------------
class HookBaseAgent < Phronomy::Agent::Base
  agent_definition id: "hook-base-agent", version: 1
  model "test-model"
  instructions "You are a helpful assistant."
end

# ---------------------------------------------------------------------------
RSpec.describe "before_completion hook" do
  # Reset class-level hooks and global config between tests.
  before do
    HookBaseAgent.instance_variable_set(:@before_completion, nil)
    Phronomy.configuration.before_completion = nil
  end

  # ---------------------------------------------------------------------------
  # BeforeCompletionContext
  # ---------------------------------------------------------------------------
  describe Phronomy::Agent::BeforeCompletionContext do
    let(:agent) { HookBaseAgent.new }
    let(:messages) { ["msg1", "msg2"] }
    let(:config) { {thread_id: "t1"} }

    it "exposes agent, messages, config, and params" do
      ctx = described_class.new(agent: agent, messages: messages, config: config, params: {temperature: 0.5})
      expect(ctx.agent).to be(agent)
      expect(ctx.messages).to eq(messages)
      expect(ctx.config).to eq(config)
      expect(ctx.params).to eq({temperature: 0.5})
    end

    it "freezes messages to prevent mutation from hooks" do
      ctx = described_class.new(agent: agent, messages: messages, config: config)
      expect(ctx.messages).to be_frozen
    end

    it "freezes params" do
      ctx = described_class.new(agent: agent, messages: messages, config: config, params: {model: "x"})
      expect(ctx.params).to be_frozen
    end
  end

  # ---------------------------------------------------------------------------
  # Class-level before_completion DSL
  # ---------------------------------------------------------------------------
  describe ".before_completion" do
    it "stores and reads a callable" do
      callable = ->(_ctx) { {temperature: 0.1} }
      HookBaseAgent.before_completion callable
      expect(HookBaseAgent._before_completion).to be(callable)
    end

    it "returns nil when not set" do
      expect(HookBaseAgent._before_completion).to be_nil
    end

    it "reads back via getter form (no argument)" do
      callable = ->(_ctx) {}
      HookBaseAgent.before_completion callable
      expect(HookBaseAgent.before_completion).to be(callable)
    end
  end

  # ---------------------------------------------------------------------------
  # Instance-level before_completion accessor
  # ---------------------------------------------------------------------------
  describe "#before_completion=" do
    it "stores an instance-level callable independent of the class" do
      agent = HookBaseAgent.new
      callable = ->(_ctx) { {model: "other"} }
      agent.before_completion = callable
      expect(agent.before_completion).to be(callable)
      expect(HookBaseAgent._before_completion).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # run_before_completion_hooks!
  # ---------------------------------------------------------------------------
  describe "#run_before_completion_hooks!" do
    let(:chat_double) { instance_double(RubyLLM::Chat, messages: [], with_temperature: nil, with_model: nil, with_params: nil) }

    it "returns empty hash when no hooks are registered" do
      agent = HookBaseAgent.new
      result = agent.send(:run_before_completion_hooks!, chat_double, {})
      expect(result).to eq({})
    end

    it "calls the global hook with a BeforeCompletionContext" do
      received_ctx = nil
      Phronomy.configuration.before_completion = ->(ctx) {
        received_ctx = ctx
        nil
      }
      agent = HookBaseAgent.new
      agent.send(:run_before_completion_hooks!, chat_double, {thread_id: "t1"})
      expect(received_ctx).to be_a(Phronomy::Agent::BeforeCompletionContext)
      expect(received_ctx.agent).to be(agent)
      expect(received_ctx.config).to eq({thread_id: "t1"})
    end

    it "calls the class-level hook" do
      called = false
      HookBaseAgent.before_completion ->(_ctx) {
        called = true
        nil
      }
      agent = HookBaseAgent.new
      agent.send(:run_before_completion_hooks!, chat_double, {})
      expect(called).to be true
    end

    it "calls the instance-level hook" do
      called = false
      agent = HookBaseAgent.new
      agent.before_completion = ->(_ctx) {
        called = true
        nil
      }
      agent.send(:run_before_completion_hooks!, chat_double, {})
      expect(called).to be true
    end

    it "calls hooks in order: global → class → instance" do
      call_order = []
      Phronomy.configuration.before_completion = ->(_ctx) {
        call_order << :global
        nil
      }
      HookBaseAgent.before_completion ->(_ctx) {
        call_order << :class
        nil
      }
      agent = HookBaseAgent.new
      agent.before_completion = ->(_ctx) {
        call_order << :instance
        nil
      }
      agent.send(:run_before_completion_hooks!, chat_double, {})
      expect(call_order).to eq([:global, :class, :instance])
    end

    it "merges params from multiple hooks (later hooks win)" do
      Phronomy.configuration.before_completion = ->(_ctx) { {temperature: 0.5, model: "model-a"} }
      agent = HookBaseAgent.new
      agent.before_completion = ->(_ctx) { {model: "model-b"} }

      allow(chat_double).to receive(:with_temperature)
      allow(chat_double).to receive(:with_model)

      result = agent.send(:run_before_completion_hooks!, chat_double, {})
      expect(result[:temperature]).to eq(0.5)
      expect(result[:model]).to eq("model-b")
    end

    it "ignores nil return values from hooks" do
      Phronomy.configuration.before_completion = ->(_ctx) {}
      HookBaseAgent.before_completion ->(_ctx) { {temperature: 0.1} }
      agent = HookBaseAgent.new

      allow(chat_double).to receive(:with_temperature)

      result = agent.send(:run_before_completion_hooks!, chat_double, {})
      expect(result).to eq({temperature: 0.1})
    end

    it "ignores empty hash return values from hooks" do
      HookBaseAgent.before_completion ->(_ctx) { {} }
      agent = HookBaseAgent.new
      result = agent.send(:run_before_completion_hooks!, chat_double, {})
      expect(result).to eq({})
    end
  end

  # ---------------------------------------------------------------------------
  # apply_before_completion_params!
  # ---------------------------------------------------------------------------
  describe "#apply_before_completion_params!" do
    let(:chat_double) { instance_double(RubyLLM::Chat) }
    let(:agent) { HookBaseAgent.new }

    it "calls with_temperature for :temperature key" do
      expect(chat_double).to receive(:with_temperature).with(0.3)
      agent.send(:apply_before_completion_params!, chat_double, {temperature: 0.3})
    end

    it "calls with_model for :model key" do
      expect(chat_double).to receive(:with_model).with("my-model", provider: nil, assume_exists: false)
      agent.send(:apply_before_completion_params!, chat_double, {model: "my-model"})
    end

    it "calls with_params for other keys" do
      expect(chat_double).to receive(:with_params).with({max_tokens: 512})
      agent.send(:apply_before_completion_params!, chat_double, {max_tokens: 512})
    end

    it "applies multiple params" do
      expect(chat_double).to receive(:with_temperature).with(0.1)
      expect(chat_double).to receive(:with_model).with("alt-model", provider: nil, assume_exists: false)
      agent.send(:apply_before_completion_params!, chat_double, {temperature: 0.1, model: "alt-model"})
    end
  end
end
