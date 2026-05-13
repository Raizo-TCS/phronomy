# frozen_string_literal: true

require_relative "spec_helper"

# Group 28: Graph Wait State / Phase
# Pairwise factors: halt_mechanism × resume_api × resume_input × phase_assertion
#
# Feasible cases: 7
# Infeasible cases: 0
#
# TC-002, TC-007: halt_mechanism=interrupt_before + resume_api=send_event
#   → ArgumentError is raised; the test verifies this error path.
#
# No LLM calls are required; all nodes perform pure data transformations.

RSpec.describe "Group 28: Graph Wait State / Phase", :integration do
  # ---------------------------------------------------------------------------
  # State class used across all test cases
  # ---------------------------------------------------------------------------

  class WaitStateTestContext
    include Phronomy::Graph::Context

    field :value, type: :replace, default: ""
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Sets up an InMemory state store and yields.
  # Resets the store to nil on exit to avoid test pollution.
  def with_in_memory_store
    store = Phronomy::StateStore::InMemory.new
    old = Phronomy.configuration.default_state_store
    Phronomy.configure { |c| c.default_state_store = store }
    yield store
  ensure
    Phronomy.configure { |c| c.default_state_store = old }
  end

  # Builds and compiles a linear graph (node_a → node_b → FINISH) that halts
  # between node_a and node_b via interrupt_before.
  # Must be called inside a with_in_memory_store block.
  def build_interrupt_before_graph
    graph = Phronomy::Graph::StateGraph.new(WaitStateTestContext)
    graph.add_node(:node_a) { |s| s.merge(value: "#{s.value}:a") }
    graph.add_node(:node_b) { |s| s.merge(value: "#{s.value}:b") }
    graph.set_entry_point(:node_a)
    graph.add_edge(:node_a, :node_b)
    graph.add_edge(:node_b, Phronomy::Graph::StateGraph::FINISH)
    compiled = graph.compile
    compiled.interrupt_before(:node_b) { :halt }
    compiled
  end

  # Builds and compiles a graph that halts via add_wait_state.
  # Graph topology: node_a → (wait) → node_b → FINISH.
  # The wait state node is named :awaiting_node_b.
  # Must be called inside a with_in_memory_store block.
  def build_wait_state_graph(resume_event: :proceed)
    graph = Phronomy::Graph::StateGraph.new(WaitStateTestContext)
    graph.add_node(:node_a) { |s| s.merge(value: "#{s.value}:a") }
    graph.add_node(:node_b) { |s| s.merge(value: "#{s.value}:b") }
    graph.set_entry_point(:node_a)
    graph.add_wait_state(
      :awaiting_node_b,
      resume_event: resume_event,
      after: :node_a,
      before: :node_b
    )
    graph.add_edge(:node_b, Phronomy::Graph::StateGraph::FINISH)
    graph.compile
  end

  # ---------------------------------------------------------------------------
  # TC-001: interrupt_before / resume_generic / no input / halted_only
  # Verify halted? and phase are correct immediately after the interrupt fires.
  # ---------------------------------------------------------------------------
  it "TC-001: interrupt_before halts with correct halted? and phase (halted_only check)" do
    with_in_memory_store do
      compiled = build_interrupt_before_graph
      thread = "tc001"

      halted = compiled.invoke({value: "start"}, config: {thread_id: thread})

      # Halt assertions — node_a ran, execution stopped before node_b
      expect(halted.value).to eq("start:a")
      expect(halted.halted?).to be(true)
      # interrupt_before sets halted_before=true + current_nodes=[:node_b]
      # phase() returns :"awaiting_node_b" for halted_before style
      expect(halted.phase).to eq(:awaiting_node_b)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: interrupt_before / send_event / with_input / complete_only
  # send_event raises ArgumentError when no wait state is registered.
  # ---------------------------------------------------------------------------
  it "TC-002: send_event raises ArgumentError for interrupt_before-halted graph" do
    with_in_memory_store do
      compiled = build_interrupt_before_graph
      thread = "tc002"

      halted = compiled.invoke({value: "start"}, config: {thread_id: thread})
      expect(halted.halted?).to be(true)

      # No wait state registered → send_event must raise ArgumentError
      expect do
        compiled.send_event(
          state: halted,
          event: :proceed,
          input: {value: "overridden"}
        )
      end.to raise_error(ArgumentError, /Unknown event/)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-003: interrupt_before / resume_generic / with_input / both
  # Verify halted phase, then resume with input and verify completion phase.
  # ---------------------------------------------------------------------------
  it "TC-003: interrupt_before resume_generic with input — both phase assertions" do
    with_in_memory_store do
      compiled = build_interrupt_before_graph
      thread = "tc003"

      halted = compiled.invoke({value: "start"}, config: {thread_id: thread})

      # Halt assertion
      expect(halted.halted?).to be(true)
      expect(halted.phase).to eq(:awaiting_node_b)

      # Resume with input (overrides value before node_b runs)
      final = compiled.resume(state: halted, input: {value: "updated"})

      # Completion assertions
      expect(final.halted?).to be(false)
      expect(final.phase).to eq(:__end__)
      # node_b appended ":b" to the overridden value
      expect(final.value).to eq("updated:b")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004: wait_state / resume_generic / no input / complete_only
  # add_wait_state halts; resume_generic resumes; verify phase == :__end__.
  # ---------------------------------------------------------------------------
  it "TC-004: add_wait_state + resume_generic (no input) — phase :__end__ after completion" do
    with_in_memory_store do
      compiled = build_wait_state_graph
      thread = "tc004"

      halted = compiled.invoke({value: "start"}, config: {thread_id: thread})

      # The graph halted at the wait state
      expect(halted.halted?).to be(true)
      expect(halted.phase).to eq(:awaiting_node_b)

      # Resume with no input
      final = compiled.resume(state: halted)

      # Completion assertions
      expect(final.halted?).to be(false)
      expect(final.phase).to eq(:__end__)
      expect(final.value).to eq("start:a:b")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-005: wait_state / send_event / no input / both
  # add_wait_state halts; send_event resumes; verify both halt and complete phases.
  # ---------------------------------------------------------------------------
  it "TC-005: add_wait_state + send_event — phase :awaiting_node_b then :__end__" do
    with_in_memory_store do
      compiled = build_wait_state_graph(resume_event: :proceed)
      thread = "tc005"

      halted = compiled.invoke({value: "start"}, config: {thread_id: thread})

      # Halt assertion
      expect(halted.halted?).to be(true)
      expect(halted.phase).to eq(:awaiting_node_b)

      # Resume via named event
      final = compiled.send_event(state: halted, event: :proceed)

      # Completion assertion
      expect(final.halted?).to be(false)
      expect(final.phase).to eq(:__end__)
      expect(final.value).to eq("start:a:b")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: wait_state / resume_generic / with_input / halted_only
  # Verify wait state halt phase; also confirm resume with input merges correctly.
  # ---------------------------------------------------------------------------
  it "TC-006: add_wait_state + resume_generic with input — halted phase and merged value" do
    with_in_memory_store do
      compiled = build_wait_state_graph
      thread = "tc006"

      halted = compiled.invoke({value: "start"}, config: {thread_id: thread})

      # Halt assertion (phase_assertion = halted_only focus)
      expect(halted.halted?).to be(true)
      expect(halted.phase).to eq(:awaiting_node_b)

      # Resume with input to verify value is correctly overridden
      final = compiled.resume(state: halted, input: {value: "replaced"})
      expect(final.value).to eq("replaced:b")
      expect(final.phase).to eq(:__end__)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-007: interrupt_before / send_event / no input / halted_only
  # Verify halt phase; send_event raises ArgumentError (error path).
  # ---------------------------------------------------------------------------
  it "TC-007: interrupt_before halted — halted? and phase verified; send_event raises ArgumentError" do
    with_in_memory_store do
      compiled = build_interrupt_before_graph
      thread = "tc007"

      halted = compiled.invoke({value: "start"}, config: {thread_id: thread})

      # Halt assertion
      expect(halted.halted?).to be(true)
      expect(halted.phase).to eq(:awaiting_node_b)

      # send_event must raise because no wait state is registered
      expect do
        compiled.send_event(state: halted, event: :some_event)
      end.to raise_error(ArgumentError, /Unknown event/)
    end
  end
end
