# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"

# Group 36: Bounded dispatch_parallel
# Pairwise factors: bp_max_concurrency × bp_on_error × bp_task_outcome
# Generated stubs: 9 cases
#
# Infeasible cases: None — all 9 combinations are structurally valid.
#
# LLM required: None — all tests use stub agents without LLM calls.

RSpec.describe "Group 36: Bounded dispatch_parallel", :integration do
  let(:orchestrator) { IntegrationFactors.bp_orchestrator_class.new }

  # ---------------------------------------------------------------------------
  # TC-001: nil / raise / all_succeed
  #
  # No concurrency cap; all tasks succeed.
  # Expected: results array fully populated in input order; no exception.
  # ---------------------------------------------------------------------------
  describe "TC-001: max_concurrency=nil / on_error=raise / all_succeed" do
    it "returns all results in input order" do
      tasks = IntegrationFactors.bp_tasks("all_succeed")
      max_c = IntegrationFactors.bp_max_concurrency("nil", task_count: tasks.length)
      results = orchestrator.dispatch_parallel(*tasks, max_concurrency: max_c, on_error: :raise)
      expect(results.size).to eq(3)
      expect(results.map { |r| r[:output] }).to eq(["ok:t0", "ok:t1", "ok:t2"])
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: nil / skip / some_fail
  #
  # No concurrency cap; one task fails, others succeed.
  # Expected: failed slot returns nil; no exception raised.
  # ---------------------------------------------------------------------------
  describe "TC-002: max_concurrency=nil / on_error=skip / some_fail" do
    it "returns nil for the failing task and results for the others" do
      tasks = IntegrationFactors.bp_tasks("some_fail")
      max_c = IntegrationFactors.bp_max_concurrency("nil", task_count: tasks.length)
      results = orchestrator.dispatch_parallel(*tasks, max_concurrency: max_c, on_error: :skip)
      expect(results[0][:output]).to eq("ok:t0")
      expect(results[1]).to be_nil
      expect(results[2][:output]).to eq("ok:t2")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-003: nil / raise / all_fail
  #
  # No concurrency cap; all tasks fail.
  # Expected: all tasks run to completion; first error in input order re-raised.
  # ---------------------------------------------------------------------------
  describe "TC-003: max_concurrency=nil / on_error=raise / all_fail" do
    it "re-raises the first-input-order error after all tasks complete" do
      tasks = IntegrationFactors.bp_tasks("all_fail")
      max_c = IntegrationFactors.bp_max_concurrency("nil", task_count: tasks.length)
      expect {
        orchestrator.dispatch_parallel(*tasks, max_concurrency: max_c, on_error: :raise)
      }.to raise_error(RuntimeError, "task_error")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004: one / raise / some_fail
  #
  # Serial execution (max_concurrency: 1); one task fails.
  # Expected: all tasks run; first error re-raised; results for successful tasks
  # are discarded by the exception but the run count is verifiable.
  # ---------------------------------------------------------------------------
  describe "TC-004: max_concurrency=1 / on_error=raise / some_fail" do
    it "runs all tasks serially and re-raises the failing task's error" do
      tasks = IntegrationFactors.bp_tasks("some_fail")
      max_c = IntegrationFactors.bp_max_concurrency("one")
      expect {
        orchestrator.dispatch_parallel(*tasks, max_concurrency: max_c, on_error: :raise)
      }.to raise_error(RuntimeError, "task_error")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-005: one / skip / all_succeed
  #
  # Serial execution (max_concurrency: 1); all tasks succeed.
  # Expected: results fully populated in input order.
  # ---------------------------------------------------------------------------
  describe "TC-005: max_concurrency=1 / on_error=skip / all_succeed" do
    it "returns all results in order under serial execution" do
      tasks = IntegrationFactors.bp_tasks("all_succeed")
      max_c = IntegrationFactors.bp_max_concurrency("one")
      results = orchestrator.dispatch_parallel(*tasks, max_concurrency: max_c, on_error: :skip)
      expect(results.map { |r| r[:output] }).to eq(["ok:t0", "ok:t1", "ok:t2"])
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: one / skip / all_fail
  #
  # Serial execution; all tasks fail with on_error: :skip.
  # Expected: all slots return nil; no exception raised.
  # ---------------------------------------------------------------------------
  describe "TC-006: max_concurrency=1 / on_error=skip / all_fail" do
    it "returns all-nil results without raising when all tasks fail" do
      tasks = IntegrationFactors.bp_tasks("all_fail")
      max_c = IntegrationFactors.bp_max_concurrency("one")
      results = orchestrator.dispatch_parallel(*tasks, max_concurrency: max_c, on_error: :skip)
      expect(results).to eq([nil, nil, nil])
    end
  end

  # ---------------------------------------------------------------------------
  # TC-007: gt_tasks / raise / all_succeed
  #
  # max_concurrency exceeds task count (effectively unbounded); all succeed.
  # Expected: same as nil — results fully populated in order.
  # ---------------------------------------------------------------------------
  describe "TC-007: max_concurrency>tasks / on_error=raise / all_succeed" do
    it "returns all results when concurrency cap exceeds task count" do
      tasks = IntegrationFactors.bp_tasks("all_succeed")
      max_c = IntegrationFactors.bp_max_concurrency("gt_tasks", task_count: tasks.length)
      results = orchestrator.dispatch_parallel(*tasks, max_concurrency: max_c, on_error: :raise)
      expect(results.map { |r| r[:output] }).to eq(["ok:t0", "ok:t1", "ok:t2"])
    end
  end

  # ---------------------------------------------------------------------------
  # TC-008: gt_tasks / skip / some_fail
  #
  # Concurrency cap above task count; one task fails; on_error: :skip.
  # Expected: failed slot returns nil; no exception.
  # ---------------------------------------------------------------------------
  describe "TC-008: max_concurrency>tasks / on_error=skip / some_fail" do
    it "returns nil for the failing task with a high concurrency cap" do
      tasks = IntegrationFactors.bp_tasks("some_fail")
      max_c = IntegrationFactors.bp_max_concurrency("gt_tasks", task_count: tasks.length)
      results = orchestrator.dispatch_parallel(*tasks, max_concurrency: max_c, on_error: :skip)
      expect(results[0][:output]).to eq("ok:t0")
      expect(results[1]).to be_nil
      expect(results[2][:output]).to eq("ok:t2")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-009: gt_tasks / raise / all_fail
  #
  # Concurrency cap above task count; all tasks fail; on_error: :raise.
  # Expected: first error in input order re-raised.
  # ---------------------------------------------------------------------------
  describe "TC-009: max_concurrency>tasks / on_error=raise / all_fail" do
    it "re-raises first-input-order error with a high concurrency cap" do
      tasks = IntegrationFactors.bp_tasks("all_fail")
      max_c = IntegrationFactors.bp_max_concurrency("gt_tasks", task_count: tasks.length)
      expect {
        orchestrator.dispatch_parallel(*tasks, max_concurrency: max_c, on_error: :raise)
      }.to raise_error(RuntimeError, "task_error")
    end
  end
end
