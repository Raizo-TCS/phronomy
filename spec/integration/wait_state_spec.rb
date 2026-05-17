# frozen_string_literal: true

require_relative "spec_helper"

# Group 28: Workflow Wait State / Phase (Phronomy::Workflow DSL)
# All halt tests use wait_state + send_event; interrupt_before/interrupt_after are removed.
# Pairwise factors: halt_mechanism x resume_api x resume_input x phase_assertion
#
# Feasible cases: 11

RSpec.describe "Group 28: Workflow Wait State / Phase", :integration do
  class WaitStateTestContext
    include Phronomy::WorkflowContext

    field :value, type: :replace, default: ""
  end

  # StateStore was removed in v0.3.0. This helper is kept as a no-op so that
  # test bodies do not need to be restructured.
  def with_in_memory_store
    yield nil
  end

  # Builds a Workflow: node_a -> wait_state(:awaiting_node_b) -> node_b -> finish.
  def build_wait_state_workflow(resume_event: :proceed)
    Phronomy::Workflow.define(WaitStateTestContext) do
      initial :node_a
      state :node_a, action: ->(s) { s.merge(value: "#{s.value}:a") }
      wait_state :awaiting_node_b
      state :node_b, action: ->(s) { s.merge(value: "#{s.value}:b") }
      after :node_a, to: :awaiting_node_b
      after :node_b, to: :__finish__
      event resume_event, from: :awaiting_node_b, to: :node_b
    end
  end

  # ---------------------------------------------------------------------------
  # TC-001: wait_state halts with correct halted? and phase (halted_only check)
  # ---------------------------------------------------------------------------
  it "TC-001: wait_state halts with correct halted? and phase" do
    with_in_memory_store do
      app = build_wait_state_workflow
      halted = app.invoke({value: "start"}, config: {thread_id: "tc001"})
      expect(halted.value).to eq("start:a")
      expect(halted.halted?).to be(true)
      expect(halted.phase).to eq(:awaiting_node_b)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: send_event with wrong event raises ArgumentError
  # ---------------------------------------------------------------------------
  it "TC-002: send_event raises ArgumentError for unknown event" do
    with_in_memory_store do
      app = build_wait_state_workflow(resume_event: :proceed)
      halted = app.invoke({value: "start"}, config: {thread_id: "tc002"})
      expect(halted.halted?).to be(true)
      expect do
        app.send_event(state: halted, event: :unknown_event, input: {value: "overridden"})
      end.to raise_error(ArgumentError, /Unknown event/)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-003: wait_state + resume with input — both halt and completion assertions
  # ---------------------------------------------------------------------------
  it "TC-003: wait_state resume with input — both phase assertions" do
    with_in_memory_store do
      app = build_wait_state_workflow
      halted = app.invoke({value: "start"}, config: {thread_id: "tc003"})
      expect(halted.halted?).to be(true)
      expect(halted.phase).to eq(:awaiting_node_b)
      final = app.resume(state: halted, input: {value: "updated"})
      expect(final.halted?).to be(false)
      expect(final.phase).to eq(:__end__)
      expect(final.value).to eq("updated:b")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004: wait_state + resume_generic (no input) — phase :__end__ after completion
  # ---------------------------------------------------------------------------
  it "TC-004: wait_state + resume_generic (no input) — phase :__end__ after completion" do
    with_in_memory_store do
      app = build_wait_state_workflow
      halted = app.invoke({value: "start"}, config: {thread_id: "tc004"})
      expect(halted.halted?).to be(true)
      expect(halted.phase).to eq(:awaiting_node_b)
      final = app.resume(state: halted)
      expect(final.halted?).to be(false)
      expect(final.phase).to eq(:__end__)
      expect(final.value).to eq("start:a:b")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-005: wait_state + send_event — phase :awaiting_node_b then :__end__
  # ---------------------------------------------------------------------------
  it "TC-005: wait_state + send_event — phase :awaiting_node_b then :__end__" do
    with_in_memory_store do
      app = build_wait_state_workflow(resume_event: :proceed)
      halted = app.invoke({value: "start"}, config: {thread_id: "tc005"})
      expect(halted.halted?).to be(true)
      expect(halted.phase).to eq(:awaiting_node_b)
      final = app.send_event(state: halted, event: :proceed)
      expect(final.halted?).to be(false)
      expect(final.phase).to eq(:__end__)
      expect(final.value).to eq("start:a:b")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: wait_state + resume_generic with input — halted phase and merged value
  # ---------------------------------------------------------------------------
  it "TC-006: wait_state + resume_generic with input — halted phase and merged value" do
    with_in_memory_store do
      app = build_wait_state_workflow
      halted = app.invoke({value: "start"}, config: {thread_id: "tc006"})
      expect(halted.halted?).to be(true)
      expect(halted.phase).to eq(:awaiting_node_b)
      final = app.resume(state: halted, input: {value: "replaced"})
      expect(final.value).to eq("replaced:b")
      expect(final.phase).to eq(:__end__)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-007: wait_state halt — halted? and phase verified; wrong event raises ArgumentError
  # ---------------------------------------------------------------------------
  it "TC-007: wait_state halted — halted? and phase verified; wrong send_event raises ArgumentError" do
    with_in_memory_store do
      app = build_wait_state_workflow
      halted = app.invoke({value: "start"}, config: {thread_id: "tc007"})
      expect(halted.halted?).to be(true)
      expect(halted.phase).to eq(:awaiting_node_b)
      expect do
        app.send_event(state: halted, event: :some_event)
      end.to raise_error(ArgumentError, /Unknown event/)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-008: wait_state always-halt — halts before node_b
  # ---------------------------------------------------------------------------
  it "TC-008: wait_state — halts before node_b" do
    with_in_memory_store do
      app = build_wait_state_workflow
      halted = app.invoke({value: "start"}, config: {thread_id: "tc008"})
      expect(halted.halted?).to be(true)
      expect(halted.phase).to eq(:awaiting_node_b)
      expect(halted.value).to eq("start:a")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-009: send_event(:resume) resumes wait_state halt
  # ---------------------------------------------------------------------------
  it "TC-009: send_event(:resume) resumes wait_state halt" do
    with_in_memory_store do
      app = build_wait_state_workflow
      halted = app.invoke({value: "x"}, config: {thread_id: "tc009"})
      expect(halted.halted?).to be(true)
      final = app.send_event(state: halted, event: :resume)
      expect(final.halted?).to be(false)
      expect(final.phase).to eq(:__end__)
      expect(final.value).to eq("x:a:b")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-010: send_event(:resume) with input resumes wait_state halt
  # ---------------------------------------------------------------------------
  it "TC-010: send_event(:resume) with input resumes wait_state halt" do
    with_in_memory_store do
      app = build_wait_state_workflow
      halted = app.invoke({value: "y"}, config: {thread_id: "tc010"})
      expect(halted.halted?).to be(true)
      final = app.send_event(state: halted, event: :resume, input: {value: "replaced"})
      expect(final.phase).to eq(:__end__)
      expect(final.value).to eq("replaced:b")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-011: send_event(:resume) resumes wait_state with named event
  # ---------------------------------------------------------------------------
  it "TC-011: send_event(:resume) resumes wait_state (named proceed event)" do
    with_in_memory_store do
      app = build_wait_state_workflow(resume_event: :proceed)
      halted = app.invoke({value: "z"}, config: {thread_id: "tc011"})
      expect(halted.halted?).to be(true)
      final = app.send_event(state: halted, event: :resume)
      expect(final.phase).to eq(:__end__)
      expect(final.value).to eq("z:a:b")
    end
  end
end
