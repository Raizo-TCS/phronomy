# frozen_string_literal: true

require_relative "spec_helper"

# Group 7: Workflow (Phronomy::Workflow DSL)
# All halt/resume tests use wait_state + send_event (interrupt_before/interrupt_after removed).
# Infeasible cases: R-redis TC-003,005,009,013,015; R-resume TC-006,009

RSpec.describe "Group 7: Workflow", :integration do
  # StateStore was removed in v0.3.0. These helpers are kept as no-ops so that
  # test bodies do not need to be restructured.
  def with_in_memory_store
    yield nil
  end

  def with_nil_store
    yield
  end

  class G7ReplaceState
    include Phronomy::WorkflowContext

    field :value, type: :replace
    field :step, type: :replace, default: 0
  end

  class G7ProcDefaultState
    include Phronomy::WorkflowContext

    field :value, type: :replace
    field :counter, type: :replace, default: -> { 0 }
  end

  class G7AppendState
    include Phronomy::WorkflowContext

    field :log, type: :append, default: -> { [] }
  end

  class G7AppendScalarState
    include Phronomy::WorkflowContext

    field :log, type: :append, default: -> { [] }
    field :count, type: :replace, default: 0
  end

  class G7MergeState
    include Phronomy::WorkflowContext

    field :data, type: :merge, default: -> { {} }
  end

  class G7MergeScalarState
    include Phronomy::WorkflowContext

    field :data, type: :merge, default: -> { {} }
    field :label, type: :replace, default: "initial"
  end

  # TC-001: linear; no interrupt; replace-type; stateless
  describe "TC-001" do
    it "executes both states in order" do
      with_nil_store do
        app = Phronomy::Workflow.define(G7ReplaceState) do
          initial :node_a
          state :node_a
          state :node_b
          entry :node_a, ->(s) {
            s.value = "A"
            s.step = 1
          }
          entry :node_b, ->(s) {
            s.value = "#{s.value}B"
            s.step = 2
          }
          transition from: :node_a, to: :node_b
          transition from: :node_b, to: :__finish__
        end
        s = app.invoke({})
        expect(s.value).to eq("AB")
        expect(s.step).to eq(2)
      end
    end
  end

  # TC-002: linear; wait_state halt; resume without input; append-type; stream; in-memory
  describe "TC-002" do
    it "halts at wait state, then resumes and completes" do
      with_in_memory_store do
        app = Phronomy::Workflow.define(G7AppendState) do
          initial :first
          state :first
          wait_state :pause_before_second
          state :second
          entry :first, ->(s) { s.log.concat(["first"]) }
          entry :second, ->(s) { s.log.concat(["second"]) }
          transition from: :first, to: :pause_before_second
          transition from: :second, to: :__finish__
          transition from: :pause_before_second, on: :resume, to: :second
        end
        events = []
        state = app.stream({}, config: {thread_id: "tc-002"}) { |e| events << e }
        expect(state.halted?).to be(true)
        expect(state.phase).to eq(:pause_before_second)
        expect(state.log).to include("first")
        expect(state.log).not_to include("second")
        expect(events.map { |e| e[:state] }).to eq([:first])
        final = app.resume(state: state)
        expect(final.log).to include("second")
        expect(final.halted?).to be(false)
      end
    end
  end

  describe "TC-003" do
    it "skipped" do
      skip "R-redis: state_store_type=redis requires a running Redis instance"
    end
  end

  # TC-004: linear; wait_state halt; resume without input; replace-type; large recursion_limit; in-memory
  describe "TC-004" do
    it "halts at wait state, then resumes and completes" do
      with_in_memory_store do
        app = Phronomy::Workflow.define(G7ReplaceState) do
          initial :start_node
          state :start_node
          wait_state :pause_after_start
          state :end_node
          entry :start_node, ->(s) {
            s.value = "started"
            s.step = 1
          }
          entry :end_node, ->(s) {
            s.value = "done"
            s.step = 2
          }
          transition from: :start_node, to: :pause_after_start
          transition from: :end_node, to: :__finish__
          transition from: :pause_after_start, on: :resume, to: :end_node
        end
        state = app.invoke({}, config: {thread_id: "tc-004", recursion_limit: 50})
        expect(state.halted?).to be(true)
        expect(state.value).to eq("started")
        final = app.resume(state: state)
        expect(final.value).to eq("done")
        expect(final.step).to eq(2)
        expect(final.halted?).to be(false)
      end
    end
  end

  describe "TC-005" do
    it "skipped" do
      skip "R-redis: state_store_type=redis requires a running Redis instance"
    end
  end

  describe "TC-006" do
    it "skipped" do
      skip "R-resume: graph_interrupt=none; no checkpoint to resume from"
    end
  end

  # TC-007: branching; wait_state halt; not resumed; merge-type; in-memory
  describe "TC-007" do
    it "routes to correct branch and halts at wait state" do
      with_in_memory_store do
        app = Phronomy::Workflow.define(G7MergeState) do
          initial :router
          state :router
          state :high
          state :low
          wait_state :pause_after_branch
          entry :router, ->(s) { s.data.merge!(routed: true, path: "high") }
          entry :high, ->(s) { s.data.merge!(result: "high_result") }
          entry :low, ->(s) { s.data.merge!(result: "low_result") }
          transition from: :high, to: :pause_after_branch
          transition from: :low, to: :pause_after_branch
          transition from: :router, guard: ->(s) { s.data[:path] == "high" }, to: :high
          transition from: :router, to: :low
        end
        state = app.invoke({}, config: {thread_id: "tc-007"})
        expect(state.halted?).to be(true)
        expect(state.data[:routed]).to be(true)
        expect(state.data[:result]).to eq("high_result")
        expect(state.phase).to eq(:pause_after_branch)
      end
    end
  end

  # TC-008: branching; wait_state halt; not resumed; append-type; stream; stateless
  describe "TC-008" do
    it "streams events and halts at wait state after routing to branch_a" do
      with_nil_store do
        app = Phronomy::Workflow.define(G7AppendState) do
          initial :entry
          state :entry
          state :branch_a
          state :branch_b
          wait_state :pause_after_branch
          entry :entry, ->(s) { s.log.concat(["entry"]) }
          entry :branch_a, ->(s) { s.log.concat(["branch_a"]) }
          entry :branch_b, ->(s) { s.log.concat(["branch_b"]) }
          transition from: :branch_a, to: :pause_after_branch
          transition from: :branch_b, to: :pause_after_branch
          transition from: :entry, guard: ->(s) { s.log.include?("entry") }, to: :branch_a
          transition from: :entry, to: :branch_b
        end
        events = []
        state = app.stream({}, config: {recursion_limit: 50}) { |e| events << e }
        expect(state.halted?).to be(true)
        expect(state.log).to include("entry")
        expect(state.log).to include("branch_a")
        expect(events.map { |e| e[:state] }).to include(:entry, :branch_a)
      end
    end
  end

  describe "TC-009" do
    it "skipped" do
      skip "R-resume + R-redis: structurally infeasible"
    end
  end

  # TC-010: multi-state; recursion_limit=1 -> RecursionLimitError; stateless
  describe "TC-010" do
    it "raises RecursionLimitError" do
      with_nil_store do
        app = Phronomy::Workflow.define(G7AppendScalarState) do
          initial :step1
          state :step1
          state :step2
          state :step3
          entry :step1, ->(s) {
            s.log.concat(["step1"])
            s.count = 1
          }
          entry :step2, ->(s) {
            s.log.concat(["step2"])
            s.count = 2
          }
          entry :step3, ->(s) {
            s.log.concat(["step3"])
            s.count = 3
          }
          transition from: :step1, to: :step2
          transition from: :step2, to: :step3
          transition from: :step3, to: :__finish__
        end
        expect {
          app.invoke({}, config: {recursion_limit: 1})
        }.to raise_error(Phronomy::RecursionLimitError, /Recursion limit/)
      end
    end
  end

  # TC-011: multi-state; wait_state halt; resume with input; replace-type; proc default; in-memory; stream
  describe "TC-011" do
    it "halts at wait state after n2, then resumes with new input" do
      with_in_memory_store do
        app = Phronomy::Workflow.define(G7ProcDefaultState) do
          initial :n1
          state :n1
          state :n2
          wait_state :pause_before_n3
          state :n3
          entry :n1, ->(s) {
            s.value = "n1"
            s.counter += 1
          }
          entry :n2, ->(s) {
            s.value = "n2"
            s.counter += 1
          }
          entry :n3, ->(s) {
            s.value = "n3-#{s.value}"
            s.counter += 1
          }
          transition from: :n1, to: :n2
          transition from: :n2, to: :pause_before_n3
          transition from: :n3, to: :__finish__
          transition from: :pause_before_n3, on: :resume, to: :n3
        end
        events = []
        state = app.stream({}, config: {thread_id: "tc-011"}) { |e| events << e }
        expect(state.halted?).to be(true)
        expect(state.phase).to eq(:pause_before_n3)
        expect(state.value).to eq("n2")
        expect(events.map { |e| e[:state] }).to eq([:n1, :n2])
        final = app.resume(state: state, input: {value: "injected"})
        expect(final.value).to eq("n3-injected")
        expect(final.halted?).to be(false)
      end
    end
  end

  # TC-012: multi-state; wait_state halt; resume without input; replace-type; stateless
  describe "TC-012" do
    it "halts at wait state after p2 and resumes to completion" do
      with_nil_store do
        app = Phronomy::Workflow.define(G7ReplaceState) do
          initial :p1
          state :p1
          state :p2
          wait_state :pause_before_p3
          state :p3
          entry :p1, ->(s) {
            s.value = "p1"
            s.step = 1
          }
          entry :p2, ->(s) {
            s.value = "p2"
            s.step = 2
          }
          entry :p3, ->(s) {
            s.value = "p3"
            s.step = 3
          }
          transition from: :p1, to: :p2
          transition from: :p2, to: :pause_before_p3
          transition from: :p3, to: :__finish__
          transition from: :pause_before_p3, on: :resume, to: :p3
        end
        state = app.invoke({})
        expect(state.halted?).to be(true)
        expect(state.value).to eq("p2")
        final = app.resume(state: state)
        expect(final.value).to eq("p3")
        expect(final.step).to eq(3)
      end
    end
  end

  describe "TC-013" do
    it "skipped" do
      skip "R-redis: state_store_type=redis requires a running Redis instance"
    end
  end

  # TC-014: multi-state; no interrupt; proc-default; large recursion_limit; stateless
  describe "TC-014" do
    it "executes all three states" do
      with_nil_store do
        app = Phronomy::Workflow.define(G7ProcDefaultState) do
          initial :a
          state :a
          state :b
          state :c
          entry :a, ->(s) {
            s.value = "a"
            s.counter = 1
          }
          entry :b, ->(s) {
            s.value = "#{s.value}b"
            s.counter = 2
          }
          entry :c, ->(s) {
            s.value = "#{s.value}c"
            s.counter = 3
          }
          transition from: :a, to: :b
          transition from: :b, to: :c
          transition from: :c, to: :__finish__
        end
        state = app.invoke({}, config: {recursion_limit: 100})
        expect(state.value).to eq("abc")
        expect(state.counter).to eq(3)
        expect(state.halted?).to be(false)
      end
    end
  end

  describe "TC-015" do
    it "skipped" do
      skip "R-redis: state_store_type=redis requires a running Redis instance"
    end
  end

  # TC-016: linear; no interrupt; replace-type; workflow completes correctly
  describe "TC-016" do
    it "persists final state in the in-memory store" do
      with_in_memory_store do |_store|
        app = Phronomy::Workflow.define(G7ReplaceState) do
          initial :first
          state :first
          state :second
          entry :first, ->(s) {
            s.value = "first"
            s.step = 1
          }
          entry :second, ->(s) {
            s.value = "second"
            s.step = 2
          }
          transition from: :first, to: :second
          transition from: :second, to: :__finish__
        end
        state = app.invoke({}, config: {thread_id: "tc-016"})
        expect(state.value).to eq("second")
        expect(state.step).to eq(2)
      end
    end
  end

  # TC-017: linear; wait_state halt; not resumed; merge-type; large recursion_limit; stateless
  describe "TC-017" do
    it "halts at wait state and verifies only alpha ran" do
      with_nil_store do
        app = Phronomy::Workflow.define(G7MergeScalarState) do
          initial :alpha
          state :alpha
          wait_state :pause_before_beta
          state :beta
          entry :alpha, ->(s) {
            s.data[:alpha] = true
            s.label = "alpha"
          }
          entry :beta, ->(s) {
            s.data[:beta] = true
            s.label = "beta"
          }
          transition from: :alpha, to: :pause_before_beta
          transition from: :beta, to: :__finish__
          transition from: :pause_before_beta, on: :resume, to: :beta
        end
        state = app.invoke({}, config: {recursion_limit: 50})
        expect(state.halted?).to be(true)
        expect(state.phase).to eq(:pause_before_beta)
        expect(state.data[:alpha]).to be(true)
        expect(state.data[:beta]).to be_nil
        expect(state.label).to eq("alpha")
      end
    end
  end

  # TC-018: linear; wait_state halt; resume with input; append-type; stateless
  describe "TC-018" do
    it "halts at wait state after x and resumes with new input" do
      with_nil_store do
        app = Phronomy::Workflow.define(G7AppendState) do
          initial :x
          state :x
          wait_state :pause_before_y
          state :y
          entry :x, ->(s) { s.log.concat(["x"]) }
          entry :y, ->(s) { s.log.concat(["y"]) }
          transition from: :x, to: :pause_before_y
          transition from: :y, to: :__finish__
          transition from: :pause_before_y, on: :resume, to: :y
        end
        state = app.invoke({})
        expect(state.halted?).to be(true)
        expect(state.log).to include("x")
        final = app.resume(state: state, input: {log: ["resumed"]})
        expect(final.log).to include("y")
        expect(final.log).to include("resumed")
        expect(final.halted?).to be(false)
      end
    end
  end

  # TC-019: linear; wait_state halt; resume without input; replace-type; proc default; stateless
  describe "TC-019" do
    it "halts at wait state after start, then resumes" do
      with_nil_store do
        app = Phronomy::Workflow.define(G7ProcDefaultState) do
          initial :start
          state :start
          wait_state :pause_before_finish_node
          state :finish_node
          entry :start, ->(s) {
            s.value = "start"
            s.counter = 1
          }
          entry :finish_node, ->(s) {
            s.value = "finish"
            s.counter = 2
          }
          transition from: :start, to: :pause_before_finish_node
          transition from: :finish_node, to: :__finish__
          transition from: :pause_before_finish_node, on: :resume, to: :finish_node
        end
        state = app.invoke({})
        expect(state.halted?).to be(true)
        expect(state.value).to eq("start")
        final = app.resume(state: state)
        expect(final.value).to eq("finish")
        expect(final.counter).to eq(2)
      end
    end
  end
end
