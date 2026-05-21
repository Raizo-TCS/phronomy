# frozen_string_literal: true

require_relative "spec_helper"

# Group 29: Phronomy::Workflow DSL
# Pairwise factors: workflow_shape × halt_mechanism × resume_api × guard_condition
#
# Feasible cases: 8
# Infeasible cases: 0
#
# No LLM calls are required; all states perform pure data transformations.

RSpec.describe "Group 29: Phronomy::Workflow DSL", :integration do
  # ---------------------------------------------------------------------------
  # Context class used across all test cases
  # ---------------------------------------------------------------------------

  class WorkflowTestContext
    include Phronomy::WorkflowContext

    field :value, type: :replace, default: ""
    field :score, type: :replace, default: 0
    field :path, type: :append, default: -> { [] }
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # StateStore was removed in v0.3.0. This helper is kept as a no-op so that
  # test bodies do not need to be restructured.
  def with_in_memory_store
    yield nil
  end

  # ---------------------------------------------------------------------------
  # Test cases
  # ---------------------------------------------------------------------------

  # TC-001: linear workflow completes without halting
  it "TC-001: linear workflow — runs all states and reaches __end__" do
    with_in_memory_store do
      step_a = ->(s) { s.value = "#{s.value}:a" }
      step_b = ->(s) { s.value = "#{s.value}:b" }

      app = Phronomy::Workflow.define(WorkflowTestContext) do
        initial :step_a
        state :step_a
        state :step_b
        entry :step_a, step_a
        entry :step_b, step_b
        transition from: :step_a, to: :step_b
        transition from: :step_b, to: :__finish__
      end

      result = app.invoke({value: "start"})

      expect(result.halted?).to be(false)
      expect(result.phase).to eq(:__end__)
      expect(result.value).to eq("start:a:b")
    end
  end

  # TC-002: wait_state halts execution, phase is set correctly
  it "TC-002: wait_state — halts at the declared wait state" do
    with_in_memory_store do
      propose = ->(s) { s.value = "#{s.value}:proposed" }
      execute = ->(s) { s.value = "#{s.value}:executed" }

      app = Phronomy::Workflow.define(WorkflowTestContext) do
        initial :propose
        state :propose
        wait_state :awaiting_approval
        state :execute
        entry :propose, propose
        entry :execute, execute
        transition from: :propose, to: :awaiting_approval
        transition from: :execute, to: :__finish__
        transition from: :awaiting_approval, on: :approve, to: :execute
      end

      halted = app.invoke({value: "x"})

      expect(halted.halted?).to be(true)
      expect(halted.phase).to eq(:awaiting_approval)
      expect(halted.value).to eq("x:proposed")
    end
  end

  # TC-003: send_event resumes from wait_state
  it "TC-003: send_event(:approve) resumes from wait_state and completes" do
    with_in_memory_store do
      propose = ->(s) { s.value = "#{s.value}:proposed" }
      execute = ->(s) { s.value = "#{s.value}:executed" }

      app = Phronomy::Workflow.define(WorkflowTestContext) do
        initial :propose
        state :propose
        wait_state :awaiting_approval
        state :execute
        entry :propose, propose
        entry :execute, execute
        transition from: :propose, to: :awaiting_approval
        transition from: :execute, to: :__finish__
        transition from: :awaiting_approval, on: :approve, to: :execute
      end

      halted = app.invoke({value: "y"})
      final = app.send_event(state: halted, event: :approve)

      expect(final.phase).to eq(:__end__)
      expect(final.value).to eq("y:proposed:executed")
    end
  end

  # TC-004: send_event(:resume) works as generic resume on wait_state
  it "TC-004: send_event(:resume) — generic resume on wait_state" do
    with_in_memory_store do
      node_a = ->(s) { s.value = "#{s.value}:a" }
      node_b = ->(s) { s.value = "#{s.value}:b" }

      app = Phronomy::Workflow.define(WorkflowTestContext) do
        initial :node_a
        state :node_a
        wait_state :waiting
        state :node_b
        entry :node_a, node_a
        entry :node_b, node_b
        transition from: :node_a, to: :waiting
        transition from: :node_b, to: :__finish__
        transition from: :waiting, on: :proceed, to: :node_b
      end

      halted = app.invoke({value: "z"})
      expect(halted.phase).to eq(:waiting)

      final = app.send_event(state: halted, event: :resume)

      expect(final.phase).to eq(:__end__)
      expect(final.value).to eq("z:a:b")
    end
  end

  # TC-005: resume() delegates to send_event(:resume)
  it "TC-005: resume() — delegates to send_event(:resume) on wait_state" do
    with_in_memory_store do
      node = ->(s) { s.value = "#{s.value}:done" }

      app = Phronomy::Workflow.define(WorkflowTestContext) do
        initial :work
        state :work
        wait_state :paused
        state :finish_step
        entry :work, node
        entry :finish_step, ->(s) { s.value = "#{s.value}:finish" }
        transition from: :work, to: :paused
        transition from: :finish_step, to: :__finish__
        transition from: :paused, on: :go, to: :finish_step
      end

      halted = app.invoke({value: "r"})
      final = app.resume(state: halted)

      expect(final.phase).to eq(:__end__)
      expect(final.value).to eq("r:done:finish")
    end
  end

  # TC-006: event with guard — takes guarded branch when guard passes
  it "TC-006: event with guard — takes guarded branch when guard returns true" do
    with_in_memory_store do
      decide = ->(s) { s.value = "#{s.value}:decided" }
      high = ->(s) { s.path << "high" }
      low = ->(s) { s.path << "low" }

      app = Phronomy::Workflow.define(WorkflowTestContext) do
        initial :decide
        state :decide
        state :high
        state :low
        entry :decide, decide
        entry :high, high
        entry :low, low
        transition from: :high, to: :__finish__
        transition from: :low, to: :__finish__
        # Guarded: score > 5 → high
        transition from: :decide, guard: ->(s) { s.score > 5 }, to: :high
        # Fallback: no guard → low
        transition from: :decide, to: :low
      end

      # High path (score = 10)
      result_high = app.invoke({value: "start", score: 10})
      expect(result_high.path).to eq(["high"])

      # Low path (score = 3)
      result_low = app.invoke({value: "start", score: 3})
      expect(result_low.path).to eq(["low"])
    end
  end

  # TC-007: send_event with input merges values before resuming
  it "TC-007: send_event with input — merges input into context before resuming" do
    with_in_memory_store do
      step = ->(s) { s.value = "#{s.value}:processed" }

      app = Phronomy::Workflow.define(WorkflowTestContext) do
        initial :wait_node
        wait_state :wait_node
        state :process
        entry :process, step
        transition from: :wait_node, on: :start, to: :process
        transition from: :process, to: :__finish__
      end

      halted = app.invoke({value: "original"})
      expect(halted.phase).to eq(:wait_node)

      final = app.send_event(state: halted, event: :start, input: {value: "overridden"})

      expect(final.phase).to eq(:__end__)
      expect(final.value).to eq("overridden:processed")
    end
  end

  # TC-008: branching wait_state — reject returns to propose
  it "TC-008: multiple events from wait_state — reject loops back" do
    with_in_memory_store do
      call_count = 0
      propose = lambda do |s|
        call_count += 1
        s.value = "#{s.value}:p#{call_count}"
      end
      execute = ->(s) { s.value = "#{s.value}:executed" }

      app = Phronomy::Workflow.define(WorkflowTestContext) do
        initial :propose
        state :propose
        wait_state :awaiting_approval
        state :execute
        entry :propose, propose
        entry :execute, execute
        transition from: :propose, to: :awaiting_approval
        transition from: :execute, to: :__finish__
        transition from: :awaiting_approval, on: :approve, to: :execute
        transition from: :awaiting_approval, on: :reject, to: :propose
      end

      # First run → halts
      halted1 = app.invoke({value: "start"})
      expect(halted1.phase).to eq(:awaiting_approval)

      # Reject → loops back to propose → halts again
      halted2 = app.send_event(state: halted1, event: :reject)
      expect(halted2.phase).to eq(:awaiting_approval)
      expect(halted2.value).to include(":p1").and include(":p2")

      # Approve → completes
      final = app.send_event(state: halted2, event: :approve)
      expect(final.phase).to eq(:__end__)
      expect(final.value).to include(":executed")
    end
  end

  # ---------------------------------------------------------------------------
  # Regression specs for Issue #110: s.merge(...) style actions must be adopted
  # ---------------------------------------------------------------------------

  # TC-merge-01: fresh-start entry action returning s.merge() is adopted
  it "TC-merge-01: fresh-start entry action returning s.merge(...) is adopted as new context" do
    with_in_memory_store do
      app = Phronomy::Workflow.define(WorkflowTestContext) do
        initial :step
        state :step
        entry :step, ->(s) { s.merge(score: 99, value: "merged") }
        transition from: :step, to: :__finish__
      end

      result = app.invoke({score: 0, value: "original"})

      expect(result.phase).to eq(:__end__)
      expect(result.score).to eq(99)
      expect(result.value).to eq("merged")
    end
  end

  # TC-merge-02: transition-target entry action returning s.merge() is adopted
  it "TC-merge-02: transition-target entry action returning s.merge(...) is adopted" do
    with_in_memory_store do
      app = Phronomy::Workflow.define(WorkflowTestContext) do
        initial :first
        state :first
        entry :first, ->(_s) { nil } # no-op: return value is not a WorkflowContext
        state :second
        entry :second, ->(s) { s.merge(score: s.score + 10) }
        transition from: :first, to: :second
        transition from: :second, to: :__finish__
      end

      result = app.invoke({score: 5})

      expect(result.phase).to eq(:__end__)
      expect(result.score).to eq(15)
    end
  end

  # TC-merge-03: post-resume entry action returning s.merge() is adopted
  it "TC-merge-03: post-resume entry action returning s.merge(...) is adopted after send_event" do
    with_in_memory_store do
      app = Phronomy::Workflow.define(WorkflowTestContext) do
        initial :prepare
        state :prepare
        entry :prepare, ->(s) { s.merge(value: "prepared") }
        wait_state :awaiting
        state :finalize
        entry :finalize, ->(s) { s.merge(score: 42) }
        transition from: :prepare, to: :awaiting
        transition from: :awaiting, on: :approve, to: :finalize
        transition from: :finalize, to: :__finish__
      end

      halted = app.invoke({value: "original", score: 0})
      expect(halted.halted?).to be(true)
      expect(halted.value).to eq("prepared")

      final = app.send_event(state: halted, event: :approve)

      expect(final.phase).to eq(:__end__)
      expect(final.score).to eq(42)
    end
  end

  # TC-merge-04: chained entry actions — second action receives context returned by first
  it "TC-merge-04: chained merge-style actions — second action receives context from first" do
    with_in_memory_store do
      app = Phronomy::Workflow.define(WorkflowTestContext) do
        initial :step
        state :step
        entry :step, ->(s) { s.merge(score: 10) }
        entry :step, ->(s) { s.merge(score: s.score + 5) } # must receive score: 10
        transition from: :step, to: :__finish__
      end

      result = app.invoke({score: 0})

      expect(result.phase).to eq(:__end__)
      expect(result.score).to eq(15) # 10 + 5, not 0 + 5
    end
  end
end

