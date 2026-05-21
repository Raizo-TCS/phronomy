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
end
