# frozen_string_literal: true

require_relative "spec_helper"

# Group 29: Phronomy::Workflow DSL
# Pairwise factors: workflow_shape × halt_mechanism × resume_api × guard_condition
#
# Feasible cases: 8
# Infeasible cases: 0
#
# No LLM calls are required; all nodes perform pure data transformations.

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
      step_a = ->(s) { s.merge(value: "#{s.value}:a") }
      step_b = ->(s) { s.merge(value: "#{s.value}:b") }

      app = Phronomy::Workflow.define(WorkflowTestContext) do
        initial :step_a
        state :step_a, action: step_a
        state :step_b, action: step_b
        after :step_a, to: :step_b
        after :step_b, to: :__finish__
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
      propose = ->(s) { s.merge(value: "#{s.value}:proposed") }
      execute = ->(s) { s.merge(value: "#{s.value}:executed") }

      app = Phronomy::Workflow.define(WorkflowTestContext) do
        initial :propose
        state :propose, action: propose
        wait_state :awaiting_approval
        state :execute, action: execute
        after :propose, to: :awaiting_approval
        after :execute, to: :__finish__
        event :approve, from: :awaiting_approval, to: :execute
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
      propose = ->(s) { s.merge(value: "#{s.value}:proposed") }
      execute = ->(s) { s.merge(value: "#{s.value}:executed") }

      app = Phronomy::Workflow.define(WorkflowTestContext) do
        initial :propose
        state :propose, action: propose
        wait_state :awaiting_approval
        state :execute, action: execute
        after :propose, to: :awaiting_approval
        after :execute, to: :__finish__
        event :approve, from: :awaiting_approval, to: :execute
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
      node_a = ->(s) { s.merge(value: "#{s.value}:a") }
      node_b = ->(s) { s.merge(value: "#{s.value}:b") }

      app = Phronomy::Workflow.define(WorkflowTestContext) do
        initial :node_a
        state :node_a, action: node_a
        wait_state :waiting
        state :node_b, action: node_b
        after :node_a, to: :waiting
        after :node_b, to: :__finish__
        event :proceed, from: :waiting, to: :node_b
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
      node = ->(s) { s.merge(value: "#{s.value}:done") }

      app = Phronomy::Workflow.define(WorkflowTestContext) do
        initial :work
        state :work, action: node
        wait_state :paused
        state :finish_step, action: ->(s) { s.merge(value: "#{s.value}:finish") }
        after :work, to: :paused
        after :finish_step, to: :__finish__
        event :go, from: :paused, to: :finish_step
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
      decide = ->(s) { s.merge(value: "#{s.value}:decided") }
      high = ->(s) { s.merge(path: "high") }
      low = ->(s) { s.merge(path: "low") }

      app = Phronomy::Workflow.define(WorkflowTestContext) do
        initial :decide
        state :decide, action: decide
        state :high, action: high
        state :low, action: low
        after :high, to: :__finish__
        after :low, to: :__finish__
        # Guarded: score > 5 → high
        event :route, from: :decide, guard: ->(s) { s.score > 5 }, to: :high
        # Fallback: no guard → low
        event :route, from: :decide, to: :low
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
      step = ->(s) { s.merge(value: "#{s.value}:processed") }

      app = Phronomy::Workflow.define(WorkflowTestContext) do
        initial :wait_node
        wait_state :wait_node
        state :process, action: step
        event :start, from: :wait_node, to: :process
        after :process, to: :__finish__
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
        s.merge(value: "#{s.value}:p#{call_count}")
      end
      execute = ->(s) { s.merge(value: "#{s.value}:executed") }

      app = Phronomy::Workflow.define(WorkflowTestContext) do
        initial :propose
        state :propose, action: propose
        wait_state :awaiting_approval
        state :execute, action: execute
        after :propose, to: :awaiting_approval
        after :execute, to: :__finish__
        event :approve, from: :awaiting_approval, to: :execute
        event :reject, from: :awaiting_approval, to: :propose
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
end
