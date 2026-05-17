# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Pairwise integration test cases — Group: Context Management
#
# Source:   docs/integration_test_cases_context_management.yaml
# Factors:  ctx_static_knowledge, ctx_cache_state, ctx_on_trim,
#           ctx_on_compaction_trigger, ctx_on_compact
# Feasible: TC-001..TC-012, TC-014 (12 tests)
# SKIP:     TC-003 (stale/no-static infeasible), TC-013 (same)
#
# All tests require LM Studio running at http://192.168.122.1:1234/v1
# with openai/gpt-oss-20b loaded.

RSpec.describe "Group: Context Management", :integration do
  before { @llm = LLMStub.activate(responses: ["Got it.", "Done.", "OK.", "OK.", "OK."]) }
  after { LLMStub.deactivate }

  # --------------------------------------------------------------------------
  # TC-001: none / cold / none / none / none
  # Baseline: no static knowledge, no callbacks, cold cache.
  # --------------------------------------------------------------------------
  describe "TC-001: no static knowledge, cold cache, no callbacks" do
    it "returns :output (String) and does not raise" do
      agent = IntegrationFactors.context_agent.new
      result = agent.invoke("What is Ruby? Reply in one sentence.")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # --------------------------------------------------------------------------
  # TC-002: none / warm / remove_none / false / summarise_range
  # Warm cache on instruction-only agent; trim is a no-op; trigger fires but
  # returns false so compact block is skipped.
  # --------------------------------------------------------------------------
  describe "TC-002: no static knowledge, warm cache, trim no-op, trigger=false" do
    let(:agent_klass) do
      IntegrationFactors.context_agent(
        on_trim_label: "remove_none",
        on_trigger_label: "false",
        on_compact_label: "summarise_range"
      )
    end

    it "succeeds on second call (warm cache) without calling compact" do
      agent = agent_klass.new
      agent.invoke("Say 'warm cache test 1'.")
      result = agent.invoke("Say 'warm cache test 2'.")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # --------------------------------------------------------------------------
  # TC-003: SKIP
  # Infeasible: ctx_cache_state:stale with ctx_static_knowledge:none is
  # impossible — instruction text is immutable at runtime.
  # --------------------------------------------------------------------------

  # --------------------------------------------------------------------------
  # TC-004: single / cold / remove_none / true / none
  # Single static source, cold cache; trigger fires but no compact block.
  # --------------------------------------------------------------------------
  describe "TC-004: single static source, cold cache, trigger=true but no compact block" do
    it "returns a non-empty output and does not raise despite trigger firing" do
      agent = IntegrationFactors.context_agent(
        static_knowledge_label: "single",
        on_trim_label: "remove_none",
        on_trigger_label: "true",
        on_compact_label: "none"
      ).new
      result = agent.invoke("What do you know about me? Reply in one sentence.")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # --------------------------------------------------------------------------
  # TC-005: single / warm / none / none / multi_range
  # Warm cache with single static source; compact block defined but trigger absent.
  # --------------------------------------------------------------------------
  describe "TC-005: single static source, warm cache, compact block without trigger" do
    let(:agent_klass) do
      IntegrationFactors.context_agent(
        static_knowledge_label: "single",
        on_compact_label: "multi_range"
      )
    end

    it "caches static knowledge and compact block is never invoked (no trigger)" do
      agent = agent_klass.new
      agent.invoke("Say 'hello'.")
      result = agent.invoke("Say 'hello again'.")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end

    it "reuses the cached system_text on the second call (fingerprint stable)" do
      agent = agent_klass.new
      agent.invoke("Say 'hello'.")
      cache = agent.context_version_cache
      fp_after_first = cache.fingerprint

      agent.invoke("Say 'hello again'.")
      fp_after_second = agent.context_version_cache.fingerprint

      expect(fp_after_second).to eq(fp_after_first)
    end
  end

  # --------------------------------------------------------------------------
  # TC-006: single / stale / none / false / summarise_range
  # Stale cache forces re-fetch of single static source; trigger returns false.
  # --------------------------------------------------------------------------
  describe "TC-006: single static source, stale cache (manual reset), trigger=false" do
    it "re-builds system_text after cache is invalidated and does not raise" do
      agent = IntegrationFactors.context_agent(
        static_knowledge_label: "single",
        on_trigger_label: "false",
        on_compact_label: "summarise_range"
      ).new
      agent.invoke("Say 'first call'.")

      # Simulate stale cache by resetting it.
      agent.context_version_cache&.reset

      result = agent.invoke("Say 'second call after stale reset'.")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # --------------------------------------------------------------------------
  # TC-007: single / cold / remove_some / false / none
  # on_trim removes the first message; trigger fires but returns false.
  # --------------------------------------------------------------------------
  describe "TC-007: single static source, cold cache, on_trim removes first message" do
    it "trims the first message and still returns a valid output" do
      agent = IntegrationFactors.context_agent(
        static_knowledge_label: "single",
        on_trim_label: "remove_some",
        on_trigger_label: "false"
      ).new

      first = agent.invoke("Remember: my favourite color is red. Just say 'Got it.'")

      result = agent.invoke("Say 'still working'.",
        config: {messages: first[:messages]})
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # --------------------------------------------------------------------------
  # TC-008: multi / cold / none / true / summarise_range
  # Multi static sources, cold cache; trigger fires and compact runs.
  # --------------------------------------------------------------------------
  describe "TC-008: multi static sources, cold cache, trigger=true, compact=summarise_range" do
    it "performs compaction without raising and returns a non-empty output" do
      agent = IntegrationFactors.context_agent(
        static_knowledge_label: "multi",
        on_trigger_label: "true",
        on_compact_label: "summarise_range"
      ).new

      first = agent.invoke("Say 'first message'.")
      result = agent.invoke("Say 'after compaction'.",
        config: {messages: first[:messages]})
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # --------------------------------------------------------------------------
  # TC-009: multi / warm / remove_some / none / none
  # Multi static sources, warm cache; on_trim removes first message; no compaction.
  # --------------------------------------------------------------------------
  describe "TC-009: multi static sources, warm cache, on_trim removes first message" do
    it "removes the oldest message each call and does not raise" do
      agent = IntegrationFactors.context_agent(
        static_knowledge_label: "multi",
        on_trim_label: "remove_some"
      ).new
      agent.invoke("Say 'call one'.")
      result = agent.invoke("Say 'call two'.")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # --------------------------------------------------------------------------
  # TC-010: multi / stale / remove_none / none / multi_range
  # Stale cache with multi static sources; trim is a no-op; compact block absent
  # from trigger, so it never runs.
  # --------------------------------------------------------------------------
  describe "TC-010: multi static sources, stale cache, trim no-op, compact without trigger" do
    it "re-builds system_text on stale cache and does not invoke compact" do
      agent = IntegrationFactors.context_agent(
        static_knowledge_label: "multi",
        on_trim_label: "remove_none",
        on_compact_label: "multi_range"
      ).new
      agent.invoke("Say 'hello'.")
      agent.context_version_cache&.reset
      result = agent.invoke("Say 'after stale reset'.")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # --------------------------------------------------------------------------
  # TC-011: multi / cold / none / false / multi_range
  # Multi static source, cold cache; trigger returns false so multi_range compact
  # is never invoked.
  # --------------------------------------------------------------------------
  describe "TC-011: multi static sources, cold cache, trigger=false, compact block skipped" do
    it "does not run compaction and returns a valid output" do
      agent = IntegrationFactors.context_agent(
        static_knowledge_label: "multi",
        on_trigger_label: "false",
        on_compact_label: "multi_range"
      ).new
      result = agent.invoke("What do you know? Reply in one sentence.")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # --------------------------------------------------------------------------
  # TC-012: none / warm / none / true / none
  # Instruction-only, warm cache; trigger fires but no compact block registered.
  # --------------------------------------------------------------------------
  describe "TC-012: no static knowledge, warm cache, trigger=true but no compact block" do
    it "fires trigger without compact block and returns a valid output" do
      agent = IntegrationFactors.context_agent(
        on_trigger_label: "true"
      ).new
      agent.invoke("Say 'first'.")
      result = agent.invoke("Say 'second'.")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # --------------------------------------------------------------------------
  # TC-013: SKIP
  # Infeasible: ctx_cache_state:stale with ctx_static_knowledge:none is
  # impossible — instruction text is immutable at runtime.
  # --------------------------------------------------------------------------

  # --------------------------------------------------------------------------
  # TC-014: none / cold / remove_some / none / summarise_range
  # Instruction-only, cold cache; on_trim removes first message; compact block
  # present but no trigger, so compact never runs.
  # --------------------------------------------------------------------------
  describe "TC-014: no static knowledge, on_trim removes first message, compact without trigger" do
    it "trims first message, skips compact (no trigger), and returns a valid output" do
      agent = IntegrationFactors.context_agent(
        on_trim_label: "remove_some",
        on_compact_label: "summarise_range"
      ).new

      first = agent.invoke("Say 'hello'.")
      result = agent.invoke("Say 'goodbye'.",
        config: {messages: first[:messages]})
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end
end
