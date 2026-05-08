# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"

# Group 23: ParallelNode Timeout and Failure Policy
#
# Factors: parallel_timeout x parallel_on_error x parallel_branch_outcome
# Generated cases: 9 (all feasible)
#
# Tests verify end-to-end behaviour of the graph when:
#   - branches all succeed (all_success)
#   - one branch raises (one_error)
#   - all branches raise (all_error)
# combined with timeout (nil / short / long) and on_error (:raise / :best_effort).

RSpec.describe "Group 23: ParallelNode Timeout and Failure Policy", :integration do
  # Convenience: branch that returns {:results => [label]}.
  def success_branch(label)
    ->(s) { {results: [label]} }
  end

  # Convenience: branch that raises RuntimeError with +msg+.
  def error_branch(msg = "branch error")
    ->(s) { raise msg.to_s }
  end

  # Convenience: branch that blocks until released via queue, then returns nil.
  def hanging_branch(barrier)
    ->(s) {
      barrier.pop
      nil
    }
  end

  # ---------------------------------------------------------------------------
  # TC-001: nil timeout; on_error: :raise; all_success
  #         Happy path — branches merge correctly; no timeout interference.
  # ---------------------------------------------------------------------------
  describe "TC-001: nil timeout; :raise; all_success — happy path merge" do
    it "merges results from all branches" do
      app = IntegrationFactors.parallel_graph(
        branches: [success_branch("a"), success_branch("b")],
        timeout: nil,
        on_error: :raise
      )
      final = app.invoke({})
      expect(final.results).to contain_exactly("a", "b")
      expect(final.parallel_errors).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: nil timeout; on_error: :best_effort; one_error
  #         One branch fails — successful results collected; error stored.
  # ---------------------------------------------------------------------------
  describe "TC-002: nil timeout; :best_effort; one_error — partial success" do
    it "collects successful result and records the error in parallel_errors" do
      app = IntegrationFactors.parallel_graph(
        branches: [success_branch("ok"), error_branch("boom")],
        timeout: nil,
        on_error: :best_effort
      )
      final = app.invoke({})
      expect(final.results).to eq(["ok"])
      expect(final.parallel_errors.size).to eq(1)
      expect(final.parallel_errors.first.message).to eq("boom")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-003: nil timeout; on_error: :raise; all_error
  #         All branches fail — first exception re-raised.
  # ---------------------------------------------------------------------------
  describe "TC-003: nil timeout; :raise; all_error — raises on branch failure" do
    it "re-raises the branch exception" do
      app = IntegrationFactors.parallel_graph(
        branches: [error_branch("err1"), error_branch("err2")],
        timeout: nil,
        on_error: :raise
      )
      expect { app.invoke({}) }.to raise_error(RuntimeError, /err/)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004: short timeout; on_error: :raise; one_error
  #         Branch raises immediately (before timeout) — RuntimeError propagates.
  # ---------------------------------------------------------------------------
  describe "TC-004: short timeout; :raise; one_error — branch error before timeout" do
    it "re-raises the branch error when it fires before the timeout" do
      # Branch raises immediately; timeout (50ms) does not fire first.
      app = IntegrationFactors.parallel_graph(
        branches: [error_branch("fast error")],
        timeout: 0.5,
        on_error: :raise
      )
      expect { app.invoke({}) }.to raise_error(RuntimeError, "fast error")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-005: short timeout; on_error: :best_effort; all_success
  #         All branches finish before timeout — full merge; no errors.
  # ---------------------------------------------------------------------------
  describe "TC-005: short timeout; :best_effort; all_success — timeout irrelevant" do
    it "merges all results when branches finish well within the timeout" do
      app = IntegrationFactors.parallel_graph(
        branches: [success_branch("x"), success_branch("y")],
        timeout: 10,
        on_error: :best_effort
      )
      final = app.invoke({})
      expect(final.results).to contain_exactly("x", "y")
      expect(final.parallel_errors).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: short timeout; on_error: :best_effort; all_error
  #         All branches raise before timeout — all errors in parallel_errors.
  # ---------------------------------------------------------------------------
  describe "TC-006: short timeout; :best_effort; all_error — all errors collected" do
    it "collects all errors and returns no results" do
      app = IntegrationFactors.parallel_graph(
        branches: [error_branch("e1"), error_branch("e2")],
        timeout: 0.5,
        on_error: :best_effort
      )
      final = app.invoke({})
      expect(final.results).to be_empty
      expect(final.parallel_errors.map(&:message)).to contain_exactly("e1", "e2")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-007: long timeout; on_error: :raise; all_success
  #         Generous timeout; full merge; no errors (same as TC-001 with timeout).
  # ---------------------------------------------------------------------------
  describe "TC-007: long timeout; :raise; all_success — timeout does not interfere" do
    it "merges results normally when timeout is generous" do
      app = IntegrationFactors.parallel_graph(
        branches: [success_branch("p"), success_branch("q")],
        timeout: 60,
        on_error: :raise
      )
      final = app.invoke({})
      expect(final.results).to contain_exactly("p", "q")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-008: long timeout; on_error: :best_effort; one_error
  #         Generous timeout; one branch fails — error collected in state.
  # ---------------------------------------------------------------------------
  describe "TC-008: long timeout; :best_effort; one_error — error in state" do
    it "collects the error with a generous timeout configured" do
      app = IntegrationFactors.parallel_graph(
        branches: [success_branch("good"), error_branch("nope")],
        timeout: 60,
        on_error: :best_effort
      )
      final = app.invoke({})
      expect(final.results).to eq(["good"])
      expect(final.parallel_errors.first.message).to eq("nope")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-009: long timeout; on_error: :raise; all_error
  #         Generous timeout; all branches fail — re-raises.
  # ---------------------------------------------------------------------------
  describe "TC-009: long timeout; :raise; all_error — re-raises branch error" do
    it "raises RuntimeError when all branches fail within a generous timeout" do
      app = IntegrationFactors.parallel_graph(
        branches: [error_branch("fail")],
        timeout: 60,
        on_error: :raise
      )
      expect { app.invoke({}) }.to raise_error(RuntimeError, "fail")
    end
  end

  # ---------------------------------------------------------------------------
  # Timeout fires — additional end-to-end cases
  # ---------------------------------------------------------------------------
  describe "TimeoutError end-to-end (short timeout; hanging branch)" do
    it "raises TimeoutError via :raise policy when branch hangs" do
      barrier = Queue.new
      app = IntegrationFactors.parallel_graph(
        branches: [hanging_branch(barrier)],
        timeout: 0.05,
        on_error: :raise
      )
      expect { app.invoke({}) }.to raise_error(Phronomy::Graph::TimeoutError)
      barrier.push(:release)
    end

    it "records TimeoutError in parallel_errors via :best_effort policy" do
      barrier = Queue.new
      app = IntegrationFactors.parallel_graph(
        branches: [success_branch("fast"), hanging_branch(barrier)],
        timeout: 0.05,
        on_error: :best_effort
      )
      final = app.invoke({})
      expect(final.results).to eq(["fast"])
      expect(final.parallel_errors.first).to be_a(Phronomy::Graph::TimeoutError)
      barrier.push(:release)
    end
  end
end
