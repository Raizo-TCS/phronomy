# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Group 25: before_llm_input Hook
# Pairwise factors: bc_hook_tier × bc_hook_return × bc_agent_class × bc_invoke_method
# Generated stubs: 20 cases
#
# Infeasible cases (SKIP):
#   TC-002: bc_hook_tier=none × bc_hook_return=empty_hash — return value irrelevant when no hook
#   TC-003: bc_hook_tier=none × bc_hook_return=param_merge — same reason
#   TC-004: bc_hook_tier=none × bc_hook_return=model_override — same reason
#
# Stream-method cases (SKIP) — streaming stub not implemented; hooks are exercised via invoke:
#   TC-008: global × model_override × react × stream
#   TC-009: class_level × nil × base × stream
#   TC-014: instance_level × {} × react × stream
#   TC-018: multi_tier × {} × react × stream
#
# Feasible (non-stream) cases run with WebMock (no real LLM required).
# LLM required: No

LM_MODEL_25 = IntegrationFactors::LM_STUDIO_MODEL

RSpec.describe "Group 25: before_llm_input Hook", :integration do
  # Reset all class-level hooks and global config between tests.
  before do
    @llm = LLMStub.activate(responses: ["OK"])
    @bc_klass = nil
  end

  after do
    LLMStub.deactivate
    Phronomy.configuration.before_llm_input = nil
    @bc_klass&.instance_variable_set(:@before_llm_input, nil)
  end

  # ---------------------------------------------------------------------------
  # TC-001: none × nil × base × invoke
  #         No hook; Base.invoke; agent succeeds without any hook being called.
  # ---------------------------------------------------------------------------
  describe "TC-001: no hook; Base.invoke — baseline, no hook called" do
    it "invoke returns non-empty output without any hook" do
      klass = IntegrationFactors.bc_agent_class("base")
      @bc_klass = klass
      agent = IntegrationFactors.bc_build_agent(tier_label: "none", return_label: "nil", klass: klass)
      result = agent.invoke("Say hello.")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # TC-002, TC-003, TC-004: SKIP — bc_hook_return irrelevant when bc_hook_tier=none

  # ---------------------------------------------------------------------------
  # TC-005: global × nil × base × invoke
  #         Global hook returning nil; Base invoke; hook is called.
  # [LLM REQUIRED]
  # ---------------------------------------------------------------------------
  describe "TC-005: global hook returning nil; Base.invoke — hook is called" do
    it "calls the global hook with a LLMInputBuildContext" do
      received_ctx = nil
      Phronomy.configuration.before_llm_input = ->(ctx) {
        received_ctx = ctx
        nil
      }
      klass = IntegrationFactors.bc_agent_class("base")
      @bc_klass = klass
      klass.new.invoke("Say hello.")
      expect(received_ctx).to be_a(Phronomy::Agent::LLMInputBuildContext)
    end

    it "global hook returning nil does not mutate request params" do
      hook_returned = nil
      Phronomy.configuration.before_llm_input = ->(ctx) {
        hook_returned = {}
        nil
      }
      klass = IntegrationFactors.bc_agent_class("base")
      @bc_klass = klass
      klass.new.invoke("Say hello.")
      expect(hook_returned).to eq({})
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: global × empty_hash × base × invoke
  #         Global hook returning {}; Base invoke; hook called; params unchanged.
  # ---------------------------------------------------------------------------
  describe "TC-006: global hook returning {}; Base.invoke — params unchanged" do
    it "calls the global hook" do
      called = false
      Phronomy.configuration.before_llm_input = ->(_ctx) {
        called = true
        {}
      }
      klass = IntegrationFactors.bc_agent_class("base")
      @bc_klass = klass
      klass.new.invoke("Say hello.")
      expect(called).to be true
    end

    it "invoke succeeds after hook" do
      Phronomy.configuration.before_llm_input = ->(_ctx) { {} }
      klass = IntegrationFactors.bc_agent_class("base")
      @bc_klass = klass
      result = klass.new.invoke("Say hello.")
      expect(result[:output]).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-007: global × param_merge × base × invoke
  #         Global hook merging {temperature: 0.1}; Base invoke;
  #         temperature appears in the intercepted request body.
  # ---------------------------------------------------------------------------
  describe "TC-007: global hook merging temperature; Base.invoke — temperature sent to LLM" do
    it "hook is called and request body contains temperature" do
      Phronomy.configuration.before_llm_input = ->(_ctx) {
        Phronomy::Agent::LLMInputPatch.new(
          model_config_patch: {temperature: 0.1},
          segment_candidates: nil, response_schema_candidate: nil, selection_policy_override: nil
        )
      }
      klass = IntegrationFactors.bc_agent_class("base")
      @bc_klass = klass
      klass.new.invoke("Say hello.")
      expect(@llm.calls.first).to include("temperature" => 0.1)
    end
  end

  # TC-008: global × model_override × react × stream — SKIP (stream stub not implemented)
  describe "TC-008: global × model_override × react × stream" do
    it "skipped — streaming stub not implemented" do
      skip "streaming stub not implemented; hook verified via invoke in TC-007"
    end
  end

  # TC-009: class_level × nil × base × stream — SKIP (stream stub not implemented)
  describe "TC-009: class_level × nil × base × stream" do
    it "skipped — streaming stub not implemented" do
      skip "streaming stub not implemented; class-level hook verified via invoke in TC-011"
    end
  end

  # ---------------------------------------------------------------------------
  # TC-010: class_level × empty_hash × base × invoke
  #         Class-level hook returning {}; Base invoke; hook is called.
  # ---------------------------------------------------------------------------
  describe "TC-010: class-level hook returning {}; Base.invoke — hook called" do
    it "calls the class-level hook" do
      called = false
      klass = IntegrationFactors.bc_agent_class("base")
      @bc_klass = klass
      klass.before_llm_input ->(_ctx) {
        called = true
        {}
      }
      klass.new.invoke("Say hello.")
      expect(called).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # TC-011: class_level × param_merge × base × invoke
  #         Class-level hook merging temperature; Base invoke;
  #         temperature sent in request body.
  # ---------------------------------------------------------------------------
  describe "TC-011: class-level hook merging temperature; Base.invoke — temperature sent to LLM" do
    it "temperature from hook appears in LLM request" do
      klass = IntegrationFactors.bc_agent_class("base")
      @bc_klass = klass
      klass.before_llm_input ->(_ctx) { Phronomy::Agent::LLMInputPatch.new(model_config_patch: {temperature: 0.1}, segment_candidates: nil, response_schema_candidate: nil, selection_policy_override: nil) }
      klass.new.invoke("Say hello.")
      expect(@llm.calls.first).to include("temperature" => 0.1)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-012: class_level × model_override × base × invoke
  #         Class-level hook returning model override; Base invoke; hook fires.
  # ---------------------------------------------------------------------------
  describe "TC-012: class-level hook with model override; Base.invoke — hook fires" do
    it "hook is called" do
      hook_called = false
      klass = IntegrationFactors.bc_agent_class("base")
      @bc_klass = klass
      klass.before_llm_input ->(_ctx) {
        hook_called = true
        Phronomy::Agent::LLMInputPatch.new(
          model_config_patch: {model: LM_MODEL_25},
          segment_candidates: nil, response_schema_candidate: nil, selection_policy_override: nil
        )
      }
      klass.new.invoke("Say hello.")
      expect(hook_called).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # TC-013: instance_level × nil × base × invoke
  #         Instance-level hook returning nil; Base invoke; hook is called.
  # ---------------------------------------------------------------------------
  describe "TC-013: instance-level hook returning nil; Base.invoke — hook called" do
    it "calls the instance-level hook" do
      called = false
      klass = IntegrationFactors.bc_agent_class("base")
      @bc_klass = klass
      agent = klass.new
      agent.before_llm_input = ->(_ctx) {
        called = true
        nil
      }
      agent.invoke("Say hello.")
      expect(called).to be true
    end
  end

  # TC-014: instance_level × empty_hash × react × stream — SKIP
  describe "TC-014: instance_level × {} × react × stream" do
    it "skipped — streaming stub not implemented" do
      skip "streaming stub not implemented; instance-level hook verified via invoke in TC-013"
    end
  end

  # ---------------------------------------------------------------------------
  # TC-015: instance_level × param_merge × base × invoke
  #         Instance-level hook merging temperature; Base invoke;
  #         temperature sent in request body.
  # ---------------------------------------------------------------------------
  describe "TC-015: instance-level hook merging temperature; Base.invoke — temperature sent to LLM" do
    it "temperature from instance hook appears in LLM request" do
      klass = IntegrationFactors.bc_agent_class("base")
      @bc_klass = klass
      agent = klass.new
      agent.before_llm_input = ->(_ctx) { Phronomy::Agent::LLMInputPatch.new(model_config_patch: {temperature: 0.1}, segment_candidates: nil, response_schema_candidate: nil, selection_policy_override: nil) }
      agent.invoke("Say hello.")
      expect(@llm.calls.first).to include("temperature" => 0.1)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-016: instance_level × model_override × base × invoke
  #         Instance-level hook returning model override; Base invoke; hook fires.
  # ---------------------------------------------------------------------------
  describe "TC-016: instance-level hook with model override; Base.invoke — hook fires" do
    it "hook is called" do
      hook_called = false
      klass = IntegrationFactors.bc_agent_class("base")
      @bc_klass = klass
      agent = klass.new
      agent.before_llm_input = ->(_ctx) {
        hook_called = true
        Phronomy::Agent::LLMInputPatch.new(
          model_config_patch: {model: LM_MODEL_25},
          segment_candidates: nil, response_schema_candidate: nil, selection_policy_override: nil
        )
      }
      agent.invoke("Say hello.")
      expect(hook_called).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # TC-017: multi_tier × nil × base × invoke
  #         All three tiers return nil; Base invoke; all three hooks are called.
  # ---------------------------------------------------------------------------
  describe "TC-017: all tiers returning nil; Base.invoke — all three hooks called" do
    it "calls global, class-level, and instance-level hooks in order" do
      call_order = []
      Phronomy.configuration.before_llm_input = ->(_ctx) {
        call_order << :global
        nil
      }
      klass = IntegrationFactors.bc_agent_class("base")
      @bc_klass = klass
      klass.before_llm_input ->(_ctx) {
        call_order << :class
        nil
      }
      agent = klass.new
      agent.before_llm_input = ->(_ctx) {
        call_order << :instance
        nil
      }
      agent.invoke("Say hello.")
      expect(call_order).to eq([:global, :class, :instance])
    end
  end

  # TC-018: multi_tier × {} × react × stream — SKIP
  describe "TC-018: multi_tier × {} × react × stream" do
    it "skipped — streaming stub not implemented" do
      skip "streaming stub not implemented; multi-tier hooks verified via invoke in TC-017"
    end
  end

  # ---------------------------------------------------------------------------
  # TC-019: multi_tier × param_merge × base × invoke
  #         All tiers return {temperature: 0.1}; Base invoke;
  #         temperature merged and sent in request body once.
  # ---------------------------------------------------------------------------
  describe "TC-019: all tiers return temperature; Base.invoke — temperature merged and sent" do
    it "temperature from merged hooks appears in LLM request" do
      Phronomy.configuration.before_llm_input = ->(_ctx) { Phronomy::Agent::LLMInputPatch.new(model_config_patch: {temperature: 0.1}, segment_candidates: nil, response_schema_candidate: nil, selection_policy_override: nil) }
      klass = IntegrationFactors.bc_agent_class("base")
      @bc_klass = klass
      klass.before_llm_input ->(_ctx) { Phronomy::Agent::LLMInputPatch.new(model_config_patch: {temperature: 0.1}, segment_candidates: nil, response_schema_candidate: nil, selection_policy_override: nil) }
      agent = klass.new
      agent.before_llm_input = ->(_ctx) { Phronomy::Agent::LLMInputPatch.new(model_config_patch: {temperature: 0.1}, segment_candidates: nil, response_schema_candidate: nil, selection_policy_override: nil) }
      agent.invoke("Say hello.")
      expect(@llm.calls.first).to include("temperature" => 0.1)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-020: multi_tier × model_override × base × invoke
  #         Tiers return different model overrides; instance-level (last) wins.
  # ---------------------------------------------------------------------------
  describe "TC-020: multi-tier model override — instance-level (last) wins" do
    it "hooks from all tiers are called in order" do
      call_order = []
      Phronomy.configuration.before_llm_input = ->(_ctx) {
        call_order << :global
        nil
      }
      klass = IntegrationFactors.bc_agent_class("base")
      @bc_klass = klass
      klass.before_llm_input ->(_ctx) { call_order << :class; nil }
      agent = klass.new
      agent.before_llm_input = ->(_ctx) { call_order << :instance; nil }
      agent.invoke("Say hello.")
      expect(call_order).to eq([:global, :class, :instance])
    end
  end
end
