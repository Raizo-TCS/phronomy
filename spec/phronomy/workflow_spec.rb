# frozen_string_literal: true

require "spec_helper"

# Regression tests for Phronomy::Workflow public API.
#
# Finding 1 — send_event API mismatch in README (Issue #<tbd>):
#   README example called `app.send_event(:approve, config: { thread_id: "..." })`
#   but the actual public signature is `send_event(state:, event:, input: nil)`.
#   These specs lock down the correct calling convention.
RSpec.describe Phronomy::Workflow do
  class WorkflowApiTestContext
    include Phronomy::WorkflowContext

    field :value, type: :replace, default: ""
  end

  def build_approval_workflow
    propose = ->(s) { s.value = "#{s.value}:proposed" }
    execute = ->(s) { s.value = "#{s.value}:executed" }

    Phronomy::Workflow.define(WorkflowApiTestContext) do
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
  end

  # Regression for Finding 1:
  # send_event must accept `state:` and `event:` as keyword arguments.
  describe "#send_event" do
    it "accepts state: and event: keyword arguments" do
      app = build_approval_workflow
      halted = app.invoke({value: "v"})

      expect { app.send_event(state: halted, event: :approve) }.not_to raise_error
    end

    # Regression for Finding 1:
    # send_event must NOT accept positional arguments as shown in the old README.
    it "raises ArgumentError when called with a positional argument instead of keywords" do
      app = build_approval_workflow
      app.invoke({value: "v"})

      expect { app.send_event(:approve) }.to raise_error(ArgumentError)
    end

    it "returns a final state with phase :__end__ after a successful resume" do
      app = build_approval_workflow
      halted = app.invoke({value: "v"})
      final = app.send_event(state: halted, event: :approve)

      expect(final.phase).to eq(:__end__)
      expect(final.value).to eq("v:proposed:executed")
    end

    it "merges input hash into state when input: is supplied" do
      app = build_approval_workflow
      halted = app.invoke({value: "v"})
      final = app.send_event(state: halted, event: :approve, input: {value: "overridden"})

      expect(final.value).to eq("overridden:executed")
    end
  end

  # Regression test for Issue #101: Workflow action return value (WorkflowContext#merge result) is silently discarded
  describe "action return value is adopted as new context (Issue #101)" do
    let(:ctx_class) do
      Class.new do
        include Phronomy::WorkflowContext

        field :value, default: "initial"
      end
    end

    it "reflects field updates when the action returns s.merge(...)" do
      app = Phronomy::Workflow.define(ctx_class) do
        initial :step_a
        state :step_a, action: ->(s) { s.merge(value: "updated") }
        transition from: :step_a, to: :__finish__
      end

      result = app.invoke({})
      expect(result.value).to eq("updated")
    end

    it "chains merge-style actions across multiple states" do
      append_ctx_class = Class.new do
        include Phronomy::WorkflowContext

        field :steps, type: :append, default: -> { [] }
      end

      app = Phronomy::Workflow.define(append_ctx_class) do
        initial :first
        state :first, action: ->(s) { s.merge(steps: "first") }
        state :second, action: ->(s) { s.merge(steps: "second") }
        transition from: :first, to: :second
        transition from: :second, to: :__finish__
      end

      result = app.invoke({})
      expect(result.steps).to eq(%w[first second])
    end
  end

  # Spec gap for Issue #102: README Workflow examples are not covered by executable specs
  describe "README Quick Start smoke test (Issue #102)" do
    it "produces correct field values using the merge-based pattern shown in the README" do
      pipeline_ctx = Class.new do
        include Phronomy::WorkflowContext

        field :draft, default: nil
        field :feedback, default: nil
        field :approved, default: false
      end

      writer = ->(s) { "draft:#{s.draft.inspect}" }
      reviewer = ->(draft) { "review:#{draft}" }

      app = Phronomy::Workflow.define(pipeline_ctx) do
        initial :write
        state :write, action: ->(s) { s.merge(draft: writer.call(s)) }
        state :review, action: ->(s) { s.merge(feedback: reviewer.call(s.draft)) }
        state :finalize, action: ->(s) { s.merge(approved: true) }
        transition from: :write, to: :review
        transition from: :review, to: :finalize
        transition from: :finalize, to: :__finish__
      end

      result = app.invoke({})
      expect(result.draft).to eq("draft:nil")
      expect(result.feedback).to eq("review:draft:nil")
      expect(result.approved).to eq(true)
    end
  end

  describe "build-time validation (Issue #124)" do
    let(:ctx) do
      Class.new do
        include Phronomy::WorkflowContext
        field :v, type: :replace, default: nil
      end
    end

    it "raises ArgumentError when a transition target is an undeclared state" do
      expect {
        Phronomy::Workflow.define(ctx) do
          initial :step
          state :step, action: ->(s) { s }
          transition from: :step, to: :missing
        end
      }.to raise_error(ArgumentError, /undefined state.*missing/i)
    end

    it "raises ArgumentError when no states are declared" do
      expect {
        Phronomy::Workflow.define(ctx) {}
      }.to raise_error(ArgumentError, /no states declared/i)
    end

    it "emits a warning for unreachable states" do
      expect {
        Phronomy::Workflow.define(ctx) do
          initial :step
          state :step, action: ->(s) { s }
          transition from: :step, to: :__finish__
          state :orphan, action: ->(s) { s }
        end
      }.to output(/unreachable state.*orphan/i).to_stderr
    end

    it "does not raise for a valid graph" do
      expect {
        Phronomy::Workflow.define(ctx) do
          initial :step
          state :step, action: ->(s) { s }
          transition from: :step, to: :__finish__
        end
      }.not_to raise_error
    end
  end
end
