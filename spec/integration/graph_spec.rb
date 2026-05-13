# frozen_string_literal: true

require_relative "spec_helper"

# Group 7: Graph
# Pairwise factors: graph_topology × graph_entry_point × graph_interrupt ×
#                   graph_resume × graph_state_field_type × graph_state_default ×
#                   graph_recursion_limit × graph_streaming × state_store_type
#
# Feasible cases: 13
# Infeasible cases: 6 (R-redis: TC-003,005,009,013,015; R-resume: TC-006,009)
#
# No LLM calls are required; all nodes perform pure data transformations.

RSpec.describe "Group 7: Graph", :integration do
  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Build an InMemory state store and wire it to Phronomy.configuration.
  def with_in_memory_store
    store = Phronomy::StateStore::InMemory.new
    old = Phronomy.configuration.default_state_store
    Phronomy.configure { |c| c.default_state_store = store }
    yield store
  ensure
    Phronomy.configure { |c| c.default_state_store = old }
  end

  # Build state store based on label.
  # Yields to block with the store (or nil).
  def with_store(label, &block)
    case label
    when :in_memory
      with_in_memory_store(&block)
    when :nil
      old = Phronomy.configuration.default_state_store
      begin
        Phronomy.configure { |c| c.default_state_store = nil }
        block.call(nil)
      ensure
        Phronomy.configure { |c| c.default_state_store = old }
      end
    end
  end

  # ---------------------------------------------------------------------------
  # State classes
  # ---------------------------------------------------------------------------

  # Replace-type state (default)
  class ReplaceState
    include Phronomy::Graph::Context

    field :value, type: :replace
    field :step, type: :replace, default: 0
  end

  # Replace-type state with proc default
  class ProcDefaultState
    include Phronomy::Graph::Context

    field :value, type: :replace
    field :counter, type: :replace, default: -> { 0 }
  end

  # Append-type state
  class AppendState
    include Phronomy::Graph::Context

    field :log, type: :append, default: -> { [] }
  end

  # Append-type state with scalar default
  class AppendScalarState
    include Phronomy::Graph::Context

    field :log, type: :append, default: -> { [] }
    field :count, type: :replace, default: 0
  end

  # Merge-type state
  class MergeState
    include Phronomy::Graph::Context

    field :data, type: :merge, default: -> { {} }
  end

  # Merge-type state with scalar default on a replace field
  class MergeScalarState
    include Phronomy::Graph::Context

    field :data, type: :merge, default: -> { {} }
    field :label, type: :replace, default: "initial"
  end

  # ---------------------------------------------------------------------------
  # TC-001: linear graph; explicit entry; no interrupt; replace-type state;
  #         invoke; nil state store — baseline stateless graph test
  # ---------------------------------------------------------------------------
  describe "TC-001: linear graph; explicit entry; no interrupt; replace-type state; invoke; stateless" do
    it "executes both nodes in order and returns the final state" do
      graph = Phronomy::Graph::StateGraph.new(ReplaceState)
      graph.add_node(:node_a) { |state| state.merge(value: "A", step: 1) }
      graph.add_node(:node_b) { |state| state.merge(value: "#{state.value}B", step: 2) }
      graph.set_entry_point(:node_a)
      graph.add_edge(:node_a, :node_b)
      graph.add_edge(:node_b, Phronomy::Graph::StateGraph::FINISH)

      old = Phronomy.configuration.default_state_store
      Phronomy.configure { |c| c.default_state_store = nil }
      app = graph.compile
      state = app.invoke({})
      Phronomy.configure { |c| c.default_state_store = old }

      expect(state.value).to eq("AB")
      expect(state.step).to eq(2)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: linear graph; implicit entry; interrupt before node; resume without
  #         input; append-type state; recursion_limit=1; stream; in-memory store
  # ---------------------------------------------------------------------------
  describe "TC-002: linear graph; implicit entry; interrupt before; resume without input; append-type; recursion_limit=1; stream; in-memory" do
    it "interrupts before the second node, then resumes and completes successfully" do
      with_in_memory_store do |store|
        graph = Phronomy::Graph::StateGraph.new(AppendState)
        graph.add_node(:first) { |state| state.merge(log: ["first"]) }
        graph.add_node(:second) { |state| state.merge(log: ["second"]) }
        graph.set_entry_point(:first)
        graph.add_edge(:first, :second)
        graph.add_edge(:second, Phronomy::Graph::StateGraph::FINISH)

        app = graph.compile
        app.interrupt_before(:second) { |_state| :halt }

        events = []
        state = app.stream({}, config: {thread_id: "tc-002"}) { |e| events << e }

        # Should halt before :second — only :first ran
        expect(state.halted_before).to eq(true)
        expect(state.current_nodes).to eq([:second])
        expect(state.log).to include("first")
        expect(state.log).not_to include("second")
        expect(events.map { |e| e[:node] }).to eq([:first])

        # Resume — :second executes and the graph completes
        # (resume uses default recursion_limit of 25; 1 node does not exceed it)
        final = app.resume(state: state, input: nil)
        expect(final.log).to include("second")
        expect(final.current_nodes).to be_empty
      end
    end
  end

  # TC-003: infeasible (R-redis)
  describe "TC-003: linear graph; interrupt after; resume with input; merge-type state; stream; redis store" do
    it "is skipped because Redis is not available in this environment" do
      skip "R-redis: state_store_type=redis requires a running Redis instance"
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004: linear graph; explicit entry; conditional_halt interrupt; resume
  #         without input; replace-type state; large recursion limit; in-memory store
  # ---------------------------------------------------------------------------
  describe "TC-004: linear graph; conditional_halt interrupt; resume without input; replace-type; large recursion_limit; in-memory" do
    it "halts when the condition triggers, then resumes and completes" do
      with_in_memory_store do |store|
        graph = Phronomy::Graph::StateGraph.new(ReplaceState)
        graph.add_node(:start_node) { |state| state.merge(value: "started", step: 1) }
        graph.add_node(:end_node) { |state| state.merge(value: "done", step: 2) }
        graph.set_entry_point(:start_node)
        graph.add_edge(:start_node, :end_node)
        graph.add_edge(:end_node, Phronomy::Graph::StateGraph::FINISH)

        app = graph.compile
        # Conditionally halt after start_node when step == 1
        app.interrupt_after(:start_node) { |state| (state.step == 1) ? :halt : nil }

        state = app.invoke({}, config: {thread_id: "tc-004", recursion_limit: 50})

        expect(state.halted_before).to eq(false)
        expect(state.current_nodes).to eq([:end_node])
        expect(state.value).to eq("started")

        # Resume without input
        final = app.resume(state: state, input: nil)
        expect(final.value).to eq("done")
        expect(final.step).to eq(2)
        expect(final.current_nodes).to be_empty
      end
    end
  end

  # TC-005: infeasible (R-redis)
  describe "TC-005: branching graph; interrupt before; not resumed; append-type state; redis store" do
    it "is skipped because Redis is not available in this environment" do
      skip "R-redis: state_store_type=redis requires a running Redis instance"
    end
  end

  # TC-006: infeasible (R-resume: interrupt=none → no checkpoint to resume from)
  describe "TC-006: branching graph; no interrupt; resume with input; replace-type; stateless" do
    it "is skipped because graph_interrupt=none provides no checkpoint for resume" do
      skip "R-resume: graph_interrupt=none; no checkpoint to resume from"
    end
  end

  # ---------------------------------------------------------------------------
  # TC-007: branching graph; implicit entry; interrupt after node; not resumed;
  #         merge-type state; in-memory store
  # ---------------------------------------------------------------------------
  describe "TC-007: branching graph; implicit entry; interrupt after node; not resumed; merge-type state; in-memory" do
    it "routes to the correct branch via conditional edge and halts after the branch node" do
      with_in_memory_store do |store|
        graph = Phronomy::Graph::StateGraph.new(MergeState)
        graph.add_node(:router) { |state| state.merge(data: {routed: true, path: "high"}) }
        graph.add_node(:high) { |state| state.merge(data: {result: "high_result"}) }
        graph.add_node(:low) { |state| state.merge(data: {result: "low_result"}) }
        graph.set_entry_point(:router)
        graph.add_edge(:high, Phronomy::Graph::StateGraph::FINISH)
        graph.add_edge(:low, Phronomy::Graph::StateGraph::FINISH)
        graph.add_conditional_edges(:router, ->(s) { (s.data[:path] == "high") ? :high : :low })

        app = graph.compile
        app.interrupt_after(:high) { |_state| :halt }

        state = app.invoke({}, config: {thread_id: "tc-007"})

        expect(state.halted_before).to eq(false)
        expect(state.data[:routed]).to eq(true)
        expect(state.data[:result]).to eq("high_result")
        expect(state.current_nodes).not_to be_empty  # halted, pending next node
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TC-008: branching graph; explicit entry; conditional_halt interrupt; not
  #         resumed; append-type state; stream; stateless
  # ---------------------------------------------------------------------------
  describe "TC-008: branching graph; explicit entry; conditional_halt interrupt; not resumed; append-type; stream; stateless" do
    it "streams events and halts when the conditional interrupt fires" do
      old = Phronomy.configuration.default_state_store
      Phronomy.configure { |c| c.default_state_store = nil }

      graph = Phronomy::Graph::StateGraph.new(AppendState)
      graph.add_node(:entry) { |state| state.merge(log: ["entry"]) }
      graph.add_node(:branch_a) { |state| state.merge(log: ["branch_a"]) }
      graph.add_node(:branch_b) { |state| state.merge(log: ["branch_b"]) }
      graph.set_entry_point(:entry)
      graph.add_conditional_edges(
        :entry,
        ->(s) { s.log.include?("entry") ? :branch_a : :branch_b }
      )
      graph.add_edge(:branch_a, Phronomy::Graph::StateGraph::FINISH)
      graph.add_edge(:branch_b, Phronomy::Graph::StateGraph::FINISH)

      app = graph.compile
      app.interrupt_before(:branch_a) { |_state| :halt }

      events = []
      state = app.stream({}, config: {recursion_limit: 50}) { |e| events << e }

      Phronomy.configure { |c| c.default_state_store = old }

      expect(state.halted_before).to eq(true)
      expect(state.log).to include("entry")
      expect(state.log).not_to include("branch_a")
      expect(events.map { |e| e[:node] }).to eq([:entry])
    end
  end

  # TC-009: infeasible (R-resume + R-redis)
  describe "TC-009: branching graph; no interrupt; resume without input; merge-type; redis store" do
    it "is skipped because graph_interrupt=none and Redis are both infeasible" do
      skip "R-resume + R-redis: structurally infeasible"
    end
  end

  # ---------------------------------------------------------------------------
  # TC-010: multi-node graph; explicit entry; no interrupt; append-type state
  #         with scalar default; recursion_limit=1 → RecursionLimitError; invoke; stateless
  # ---------------------------------------------------------------------------
  describe "TC-010: multi-node graph; recursion_limit=1 → RecursionLimitError; append-type; stateless" do
    it "raises RecursionLimitError after the first node transition" do
      old = Phronomy.configuration.default_state_store
      Phronomy.configure { |c| c.default_state_store = nil }

      graph = Phronomy::Graph::StateGraph.new(AppendScalarState)
      graph.add_node(:step1) { |state| state.merge(log: ["step1"], count: 1) }
      graph.add_node(:step2) { |state| state.merge(log: ["step2"], count: 2) }
      graph.add_node(:step3) { |state| state.merge(log: ["step3"], count: 3) }
      graph.set_entry_point(:step1)
      graph.add_edge(:step1, :step2)
      graph.add_edge(:step2, :step3)
      graph.add_edge(:step3, Phronomy::Graph::StateGraph::FINISH)

      app = graph.compile

      expect {
        app.invoke({}, config: {recursion_limit: 1})
      }.to raise_error(Phronomy::RecursionLimitError, /Recursion limit/)

      Phronomy.configure { |c| c.default_state_store = old }
    end
  end

  # ---------------------------------------------------------------------------
  # TC-011: multi-node graph; implicit entry; interrupt before node; resume
  #         with new input; replace-type state; proc default; in-memory store; stream
  # ---------------------------------------------------------------------------
  describe "TC-011: multi-node graph; implicit entry; interrupt before; resume with input; replace-type; proc default; in-memory; stream" do
    it "interrupts before the third node, then resumes with new input and completes" do
      with_in_memory_store do |store|
        graph = Phronomy::Graph::StateGraph.new(ProcDefaultState)
        graph.add_node(:n1) { |state| state.merge(value: "n1", counter: state.counter + 1) }
        graph.add_node(:n2) { |state| state.merge(value: "n2", counter: state.counter + 1) }
        graph.add_node(:n3) { |state| state.merge(value: "n3-#{state.value}", counter: state.counter + 1) }
        graph.set_entry_point(:n1)
        graph.add_edge(:n1, :n2)
        graph.add_edge(:n2, :n3)
        graph.add_edge(:n3, Phronomy::Graph::StateGraph::FINISH)

        app = graph.compile
        app.interrupt_before(:n3) { |_state| :halt }

        events = []
        state = app.stream({}, config: {thread_id: "tc-011"}) { |e| events << e }

        expect(state.halted_before).to eq(true)
        expect(state.current_nodes).to eq([:n3])
        expect(state.value).to eq("n2")
        expect(events.map { |e| e[:node] }).to eq([:n1, :n2])

        # Resume with new input overriding the value field
        final = app.resume(state: state, input: {value: "injected"})
        expect(final.value).to eq("n3-injected")
        expect(final.current_nodes).to be_empty
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TC-012: multi-node graph; explicit entry; interrupt after node; resume
  #         without new input; replace-type state; stateless (nil state store)
  # ---------------------------------------------------------------------------
  describe "TC-012: multi-node graph; explicit entry; interrupt after; resume without input; replace-type; stateless" do
    it "halts after the second node and resumes to completion without new input" do
      old = Phronomy.configuration.default_state_store
      Phronomy.configure { |c| c.default_state_store = nil }

      graph = Phronomy::Graph::StateGraph.new(ReplaceState)
      graph.add_node(:p1) { |state| state.merge(value: "p1", step: 1) }
      graph.add_node(:p2) { |state| state.merge(value: "p2", step: 2) }
      graph.add_node(:p3) { |state| state.merge(value: "p3", step: 3) }
      graph.set_entry_point(:p1)
      graph.add_edge(:p1, :p2)
      graph.add_edge(:p2, :p3)
      graph.add_edge(:p3, Phronomy::Graph::StateGraph::FINISH)

      app = graph.compile
      app.interrupt_after(:p2) { |_state| :halt }

      state = app.invoke({})

      Phronomy.configure { |c| c.default_state_store = old }

      expect(state.halted_before).to eq(false)
      expect(state.value).to eq("p2")
      expect(state.current_nodes).to eq([:p3])

      # Resume without input
      Phronomy.configure { |c| c.default_state_store = nil }
      final = app.resume(state: state)
      Phronomy.configure { |c| c.default_state_store = old }

      expect(final.value).to eq("p3")
      expect(final.step).to eq(3)
    end
  end

  # TC-013: infeasible (R-redis)
  describe "TC-013: multi-node graph; conditional_halt interrupt; resume with input; merge-type; redis store" do
    it "is skipped because Redis is not available in this environment" do
      skip "R-redis: state_store_type=redis requires a running Redis instance"
    end
  end

  # ---------------------------------------------------------------------------
  # TC-014: multi-node graph; explicit entry; no interrupt; proc-default state;
  #         large recursion_limit; invoke; stateless
  # ---------------------------------------------------------------------------
  describe "TC-014: multi-node graph; no interrupt; proc-default state; large recursion_limit; stateless" do
    it "executes all three nodes and returns the final state" do
      old = Phronomy.configuration.default_state_store
      Phronomy.configure { |c| c.default_state_store = nil }

      graph = Phronomy::Graph::StateGraph.new(ProcDefaultState)
      graph.add_node(:a) { |state| state.merge(value: "a", counter: 1) }
      graph.add_node(:b) { |state| state.merge(value: "#{state.value}b", counter: 2) }
      graph.add_node(:c) { |state| state.merge(value: "#{state.value}c", counter: 3) }
      graph.set_entry_point(:a)
      graph.add_edge(:a, :b)
      graph.add_edge(:b, :c)
      graph.add_edge(:c, Phronomy::Graph::StateGraph::FINISH)

      app = graph.compile
      state = app.invoke({}, config: {recursion_limit: 100})

      Phronomy.configure { |c| c.default_state_store = old }

      expect(state.value).to eq("abc")
      expect(state.counter).to eq(3)
      expect(state.current_nodes).to be_empty
    end
  end

  # TC-015: infeasible (R-redis)
  describe "TC-015: linear graph; no interrupt; replace-type; redis store" do
    it "is skipped because Redis is not available in this environment" do
      skip "R-redis: state_store_type=redis requires a running Redis instance"
    end
  end

  # ---------------------------------------------------------------------------
  # TC-016: linear graph; explicit entry; no interrupt; replace-type state;
  #         invoke; in-memory store — covers in-memory persistence path
  # ---------------------------------------------------------------------------
  describe "TC-016: linear graph; no interrupt; replace-type state; invoke; in-memory store" do
    it "executes both nodes and persists the final state in the in-memory store" do
      with_in_memory_store do |store|
        thread_id = "tc-016"

        graph = Phronomy::Graph::StateGraph.new(ReplaceState)
        graph.add_node(:first) { |state| state.merge(value: "first", step: 1) }
        graph.add_node(:second) { |state| state.merge(value: "second", step: 2) }
        graph.set_entry_point(:first)
        graph.add_edge(:first, :second)
        graph.add_edge(:second, Phronomy::Graph::StateGraph::FINISH)

        app = graph.compile
        state = app.invoke({}, config: {thread_id: thread_id})

        expect(state.value).to eq("second")
        expect(state.step).to eq(2)

        # Verify persisted to in-memory store
        persisted = store.load(thread_id)
        expect(persisted).not_to be_nil
        expect(persisted.value).to eq("second")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TC-017: linear graph; explicit entry; interrupt before node; not resumed;
  #         merge-type state; large recursion_limit; stateless
  # ---------------------------------------------------------------------------
  describe "TC-017: linear graph; explicit entry; interrupt before; not resumed; merge-type state; large recursion_limit; stateless" do
    it "halts before the second node and verifies only the first node ran" do
      old = Phronomy.configuration.default_state_store
      Phronomy.configure { |c| c.default_state_store = nil }

      graph = Phronomy::Graph::StateGraph.new(MergeScalarState)
      graph.add_node(:alpha) { |state| state.merge(data: {alpha: true}, label: "alpha") }
      graph.add_node(:beta) { |state| state.merge(data: {beta: true}, label: "beta") }
      graph.set_entry_point(:alpha)
      graph.add_edge(:alpha, :beta)
      graph.add_edge(:beta, Phronomy::Graph::StateGraph::FINISH)

      app = graph.compile
      app.interrupt_before(:beta) { |_state| :halt }

      state = app.invoke({}, config: {recursion_limit: 50})

      Phronomy.configure { |c| c.default_state_store = old }

      expect(state.halted_before).to eq(true)
      expect(state.current_nodes).to eq([:beta])
      expect(state.data[:alpha]).to eq(true)
      expect(state.data[:beta]).to be_nil
      expect(state.label).to eq("alpha")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-018: linear graph; explicit entry; interrupt after node; resume with
  #         input; append-type state; recursion_limit=1; stateless
  # ---------------------------------------------------------------------------
  describe "TC-018: linear graph; explicit entry; interrupt after; resume with input; append-type; recursion_limit=1; stateless" do
    it "halts after the first node and resumes with new input to completion" do
      old = Phronomy.configuration.default_state_store
      Phronomy.configure { |c| c.default_state_store = nil }

      graph = Phronomy::Graph::StateGraph.new(AppendState)
      graph.add_node(:x) { |state| state.merge(log: ["x"]) }
      graph.add_node(:y) { |state| state.merge(log: ["y"]) }
      graph.set_entry_point(:x)
      graph.add_edge(:x, :y)
      graph.add_edge(:y, Phronomy::Graph::StateGraph::FINISH)

      app = graph.compile
      app.interrupt_after(:x) { |_state| :halt }

      state = app.invoke({})

      Phronomy.configure { |c| c.default_state_store = old }

      expect(state.halted_before).to eq(false)
      expect(state.log).to include("x")
      expect(state.current_nodes).to eq([:y])

      # Resume with input — :y executes and the graph completes
      # (resume uses default recursion_limit of 25; 1 node does not exceed it)
      Phronomy.configure { |c| c.default_state_store = nil }
      final = app.resume(state: state, input: {log: ["resumed"]})
      Phronomy.configure { |c| c.default_state_store = old }

      expect(final.log).to include("y")
      expect(final.log).to include("resumed")
      expect(final.current_nodes).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-019: linear graph; explicit entry; conditional_halt interrupt; resume
  #         without input; replace-type state; proc default; recursion_limit=1; stateless
  # ---------------------------------------------------------------------------
  describe "TC-019: linear graph; explicit entry; conditional_halt interrupt; resume without input; replace-type; proc default; recursion_limit=1; stateless" do
    it "halts when condition fires, then resumes to completion" do
      old = Phronomy.configuration.default_state_store
      Phronomy.configure { |c| c.default_state_store = nil }

      graph = Phronomy::Graph::StateGraph.new(ProcDefaultState)
      graph.add_node(:start) { |state| state.merge(value: "start", counter: 1) }
      graph.add_node(:finish) { |state| state.merge(value: "finish", counter: 2) }
      graph.set_entry_point(:start)
      graph.add_edge(:start, :finish)
      graph.add_edge(:finish, Phronomy::Graph::StateGraph::FINISH)

      app = graph.compile
      app.interrupt_after(:start) { |state| (state.counter == 1) ? :halt : nil }

      state = app.invoke({})

      Phronomy.configure { |c| c.default_state_store = old }

      expect(state.halted_before).to eq(false)
      expect(state.value).to eq("start")
      expect(state.current_nodes).to eq([:finish])

      # Resume — :finish executes and the graph completes
      # (resume uses default recursion_limit of 25; 1 node does not exceed it)
      Phronomy.configure { |c| c.default_state_store = nil }
      final = app.resume(state: state, input: nil)
      Phronomy.configure { |c| c.default_state_store = old }

      expect(final.value).to eq("finish")
      expect(final.counter).to eq(2)
      expect(final.current_nodes).to be_empty
    end
  end
end
