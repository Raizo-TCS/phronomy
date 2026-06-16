# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"

# Group 21: Tool Retry (retry_on DSL)
# Factors: retry_exception_type x retry_wait_strategy x retry_times
# Generated cases: 10
# Infeasible:
#   TC-005 (runtime_error + linear + zero): wait strategy is unobservable when
#           times=0; TC-001 already covers the zero-retry path.
#           SKIP: wait strategy cannot be distinguished from TC-001 outcome.
#   TC-006 (runtime_error + fixed + zero): same reason as TC-005.
#           SKIP: duplicate of TC-001/TC-005 zero-retry pattern.

RSpec.describe "Group 21: Tool Retry", :integration do
  let(:sleep_log) { [] }

  def make_tool(exception_class:, times:, wait:, base: 1.0, succeed_after: nil)
    IntegrationFactors.retry_tool(
      exception_class: exception_class,
      times: times,
      wait: wait,
      base: base,
      sleep_log: sleep_log,
      succeed_after: succeed_after
    ).new
  end

  # ---------------------------------------------------------------------------
  # TC-001: tool_error + exponential + zero
  #         No retry configured — exception propagates immediately.
  # ---------------------------------------------------------------------------
  describe "TC-001: ToolError; exponential; times=0 — immediate propagation" do
    it "raises ToolError without any sleep" do
      tool = make_tool(exception_class: Phronomy::ToolError, times: 0, wait: :exponential)
      expect { tool.call({}) }.to raise_error(Phronomy::ToolError)
      expect(sleep_log).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: tool_error + linear + two
  #         ToolError retried twice with linear wait.
  # ---------------------------------------------------------------------------
  describe "TC-002: ToolError; linear; times=2 — retry and recover" do
    it "recovers after 2 retries and records linear sleep durations" do
      tool = make_tool(
        exception_class: Phronomy::ToolError, times: 2,
        wait: :linear, base: 1.0, succeed_after: 3
      )
      result = tool.call({})
      expect(result).to eq("recovered after 3")
      # attempt=0 → 1.0, attempt=1 → 2.0
      expect(sleep_log).to eq([1.0, 2.0])
    end

    it "re-raises after exhausting all retries" do
      tool = make_tool(exception_class: Phronomy::ToolError, times: 2, wait: :linear)
      expect { tool.call({}) }.to raise_error(Phronomy::ToolError)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-003: tool_error + fixed + three
  #         ToolError retried 3 times with a fixed wait.
  # ---------------------------------------------------------------------------
  describe "TC-003: ToolError; fixed; times=3 — exhausted retries with fixed wait" do
    it "sleeps the same duration on every retry" do
      tool = make_tool(exception_class: Phronomy::ToolError, times: 3, wait: 0.5)
      expect { tool.call({}) }.to raise_error(Phronomy::ToolError)
      expect(sleep_log).to eq([0.5, 0.5, 0.5])
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004: runtime_error + exponential + two
  #         Custom exception class retried with exponential back-off.
  # ---------------------------------------------------------------------------
  describe "TC-004: RuntimeError; exponential; times=2 — custom exception retry" do
    it "retries RuntimeError with exponential back-off and recovers" do
      tool = make_tool(
        exception_class: RuntimeError, times: 2,
        wait: :exponential, base: 1.0, succeed_after: 2
      )
      # RuntimeError from execute is wrapped as ToolError by on_error: :raise path.
      # The retry_on RuntimeError policy fires before ToolError wrapping so we
      # expect recovery here.
      result = tool.call({})
      expect(result).to eq("recovered after 2")
      expect(sleep_log).to eq([1.0])
    end

    it "records exponential sleep durations when all retries fail" do
      tool = make_tool(exception_class: RuntimeError, times: 2, wait: :exponential, base: 1.0)
      expect { tool.call({}) }.to raise_error(Phronomy::ToolError, /failure/)
      # attempt=0 → 1.0, attempt=1 → 2.0
      expect(sleep_log).to eq([1.0, 2.0])
    end
  end

  # ---------------------------------------------------------------------------
  # TC-005: runtime_error + linear + zero — INFEASIBLE
  #         wait strategy is unobservable when times=0.
  # ---------------------------------------------------------------------------
  it "TC-005: SKIP — wait strategy unobservable with times=0 (covered by TC-001)" do
    pending "SKIP: zero-retry path independent of wait strategy; see TC-001"
    raise "should be skipped"
  end

  # ---------------------------------------------------------------------------
  # TC-006: runtime_error + fixed + zero — INFEASIBLE
  #         wait strategy is unobservable when times=0.
  # ---------------------------------------------------------------------------
  it "TC-006: SKIP — wait strategy unobservable with times=0 (covered by TC-001)" do
    pending "SKIP: zero-retry path independent of wait strategy; see TC-001"
    raise "should be skipped"
  end

  # ---------------------------------------------------------------------------
  # TC-007: runtime_error + exponential + three
  #         RuntimeError retried 3 times; verify full retry count.
  # ---------------------------------------------------------------------------
  describe "TC-007: RuntimeError; exponential; times=3 — full retry count" do
    it "sleeps 3 times with exponential durations before raising" do
      tool = make_tool(exception_class: RuntimeError, times: 3, wait: :exponential, base: 1.0)
      expect { tool.call({}) }.to raise_error(Phronomy::ToolError, /failure/)
      # attempt=0 → 1.0, attempt=1 → 2.0, attempt=2 → 4.0
      expect(sleep_log).to eq([1.0, 2.0, 4.0])
    end
  end

  # ---------------------------------------------------------------------------
  # TC-008: guardrail_error + exponential + zero
  #         FilterBlockError must not be retried. times=0 so no retry anyway.
  # ---------------------------------------------------------------------------
  describe "TC-008: FilterBlockError; exponential; times=0 — no retry (times=0)" do
    it "propagates FilterBlockError immediately" do
      # FilterBlockError from execute is caught by rescue => e in #call and wrapped
      # as ToolError. retry_on FilterBlockError is NOT configured, so no retry.
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "guardrail test tool"
        def execute(**_)
          raise Phronomy::FilterBlockError, "blocked by policy"
        end
      end
      klass._sleep_proc = ->(t) { sleep_log << t }
      expect { klass.new.call({}) }.to raise_error(Phronomy::ToolError, /blocked/)
      expect(sleep_log).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-009: guardrail_error + linear + three
  #         FilterBlockError is NOT in the retry_on list — must not retry even
  #         when times=3 is configured for another exception class.
  # ---------------------------------------------------------------------------
  describe "TC-009: FilterBlockError; linear; times=3 for other exception — not retried" do
    it "does not retry FilterBlockError even when a retry policy exists for ToolError" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "guardrail+retry test tool"
        # Policy covers ToolError, NOT FilterBlockError
        retry_on Phronomy::ToolError, times: 3, wait: :linear, base: 1.0
        def execute(**_)
          raise Phronomy::FilterBlockError, "policy blocked"
        end
      end
      klass._sleep_proc = ->(t) { sleep_log << t }
      expect { klass.new.call({}) }.to raise_error(Phronomy::ToolError, /policy blocked/)
      expect(sleep_log).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-010: guardrail_error + fixed + two
  #         Same principle as TC-009 but with fixed wait and times=2.
  # ---------------------------------------------------------------------------
  describe "TC-010: FilterBlockError; fixed; times=2 for other exception — not retried" do
    it "does not retry FilterBlockError when retry_on covers RuntimeError only" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "guardrail+retry test tool"
        retry_on RuntimeError, times: 2, wait: 0.5
        def execute(**_)
          raise Phronomy::FilterBlockError, "blocked"
        end
      end
      klass._sleep_proc = ->(t) { sleep_log << t }
      expect { klass.new.call({}) }.to raise_error(Phronomy::ToolError, /blocked/)
      expect(sleep_log).to be_empty
    end
  end
end
