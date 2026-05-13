# frozen_string_literal: true

require "spec_helper"

# --- State class for testing ---
class TestState
  include Phronomy::Graph::Context

  field :value, type: :replace, default: 0
  field :messages, type: :append, default: -> { [] }
  field :metadata, type: :merge, default: -> { {} }
  field :step, type: :replace, default: nil
end

RSpec.describe Phronomy::Graph::Context do
  describe "field DSL" do
    it "defines fields as accessors" do
      s = TestState.new(value: 42)
      expect(s.value).to eq(42)
    end

    it "applies default values (scalar)" do
      s = TestState.new
      expect(s.value).to eq(0)
    end

    it "applies default values (Proc)" do
      s = TestState.new
      expect(s.messages).to eq([])
    end

    it "Proc defaults return a new object each time" do
      s1 = TestState.new
      s2 = TestState.new
      expect(s1.messages).not_to be(s2.messages)
    end
  end

  describe "#merge" do
    let(:state) { TestState.new(value: 1, messages: ["a"], metadata: {x: 1}) }

    context "type: :replace" do
      it "overwrites with the new value" do
        new_state = state.merge(value: 99)
        expect(new_state.value).to eq(99)
      end

      it "does not mutate the original state (immutable)" do
        state.merge(value: 99)
        expect(state.value).to eq(1)
      end
    end

    context "type: :append" do
      it "appends to the end of the array" do
        new_state = state.merge(messages: ["b"])
        expect(new_state.messages).to eq(["a", "b"])
      end

      it "appends multiple elements" do
        new_state = state.merge(messages: ["b", "c"])
        expect(new_state.messages).to eq(["a", "b", "c"])
      end
    end

    context "type: :merge" do
      it "merges the Hash" do
        new_state = state.merge(metadata: {y: 2})
        expect(new_state.metadata).to eq({x: 1, y: 2})
      end

      it "overwrites duplicate keys" do
        new_state = state.merge(metadata: {x: 99})
        expect(new_state.metadata).to eq({x: 99})
      end
    end

    it "preserves untouched fields" do
      new_state = state.merge(value: 99)
      expect(new_state.messages).to eq(["a"])
    end

    it "returns an instance of the same class" do
      expect(state.merge(value: 2)).to be_a(TestState)
    end
  end

  describe "#to_h" do
    it "converts all fields to a Hash" do
      s = TestState.new(value: 5, messages: ["x"])
      h = s.to_h
      expect(h[:value]).to eq(5)
      expect(h[:messages]).to eq(["x"])
    end

    it "does not include internal graph metadata" do
      s = TestState.new(value: 1)
      s.set_graph_metadata(thread_id: "t1", current_nodes: [:foo], halted_before: true)
      expect(s.to_h.keys).not_to include(:thread_id, :current_nodes, :halted_before)
    end
  end

  describe "#set_graph_metadata" do
    it "stores thread_id, current_nodes, and halted_before" do
      s = TestState.new
      s.set_graph_metadata(thread_id: "abc", current_nodes: [:foo, :bar], halted_before: true)
      expect(s.thread_id).to eq("abc")
      expect(s.current_nodes).to eq([:foo, :bar])
      expect(s.halted_before).to be(true)
    end

    it "defaults current_nodes to [] and halted_before to false" do
      s = TestState.new
      s.set_graph_metadata(thread_id: "t")
      expect(s.current_nodes).to eq([])
      expect(s.halted_before).to be(false)
    end

    it "accepts phase: to set phase directly (derives current_nodes/halted_before)" do
      s = TestState.new
      s.set_graph_metadata(thread_id: "t", phase: :awaiting_foo)
      expect(s.phase).to eq(:awaiting_foo)
      expect(s.current_nodes).to eq([:foo])
      expect(s.halted_before).to be(true)
    end

    it "phase: :__end__ clears current_nodes" do
      s = TestState.new
      s.set_graph_metadata(thread_id: "t", phase: :__end__)
      expect(s.phase).to eq(:__end__)
      expect(s.current_nodes).to eq([])
      expect(s.halted_before).to be(false)
    end

    it "phase: :some_node sets current_nodes and halted_before false" do
      s = TestState.new
      s.set_graph_metadata(thread_id: "t", phase: :some_node)
      expect(s.phase).to eq(:some_node)
      expect(s.current_nodes).to eq([:some_node])
      expect(s.halted_before).to be(false)
    end
  end

  describe "#phase" do
    it "returns :__end__ for a fresh state" do
      expect(TestState.new.phase).to eq(:__end__)
    end

    it "returns :awaiting_node when halted_before is true" do
      s = TestState.new
      s.set_graph_metadata(thread_id: "t", current_nodes: [:run_checks], halted_before: true)
      expect(s.phase).to eq(:awaiting_run_checks)
    end

    it "returns the node name when halted_before is false (interrupt_after style)" do
      s = TestState.new
      s.set_graph_metadata(thread_id: "t", current_nodes: [:run_checks], halted_before: false)
      expect(s.phase).to eq(:run_checks)
    end

    it "returns the wait state name when stored as-is in current_nodes" do
      s = TestState.new
      s.set_graph_metadata(thread_id: "t", current_nodes: [:awaiting_approval], halted_before: false)
      expect(s.phase).to eq(:awaiting_approval)
    end
  end

  describe "#halted?" do
    it "returns false for a fresh (unstarted) state" do
      expect(TestState.new.halted?).to be(false)
    end

    it "returns true when current_nodes is non-empty" do
      s = TestState.new
      s.set_graph_metadata(thread_id: "t", current_nodes: [:foo], halted_before: true)
      expect(s.halted?).to be(true)
    end

    it "returns false when current_nodes is empty (completed)" do
      s = TestState.new
      s.set_graph_metadata(thread_id: "t", current_nodes: [], halted_before: false)
      expect(s.halted?).to be(false)
    end
  end

  describe "#merge preserves internal graph metadata" do
    it "carries thread_id and current_nodes through merge" do
      s = TestState.new(value: 1)
      s.set_graph_metadata(thread_id: "t1", current_nodes: [:send], halted_before: true)
      s2 = s.merge(value: 99)
      expect(s2.thread_id).to eq("t1")
      expect(s2.current_nodes).to eq([:send])
      expect(s2.halted_before).to be(true)
    end
  end
end

RSpec.describe Phronomy::Graph::StateGraph do
  let(:graph) { described_class.new(TestState) }

  describe "#add_node" do
    it "adds the node and returns self for chaining" do
      result = graph.add_node(:search) { |s| s }
      expect(result).to be(graph)
      expect(graph.nodes).to have_key(:search)
    end

    it "accepts a callable object" do
      fn = ->(s) { s }
      graph.add_node(:fn, fn)
      expect(graph.nodes[:fn]).to be(fn)
    end
  end

  describe "#add_edge" do
    it "adds the edge and returns self for chaining" do
      result = graph.add_edge(:a, :b)
      expect(result).to be(graph)
      expect(graph.edges[:a].map { |e| e[:to] }).to include(:b)
    end

    it "adds multiple edges from the same node" do
      graph.add_edge(:a, :b).add_edge(:a, :c)
      expect(graph.edges[:a].map { |e| e[:to] }).to contain_exactly(:b, :c)
    end

    it "stores nil condition for unconditional edges" do
      graph.add_edge(:a, :b)
      expect(graph.edges[:a].first[:condition]).to be_nil
    end

    it "accepts an optional guard condition" do
      cond = ->(s) { s.value > 5 }
      graph.add_edge(:a, :b, cond)
      expect(graph.edges[:a].first[:condition]).to be(cond)
    end
  end

  describe "#add_conditional_edges" do
    it "registers the conditional edge" do
      cond = ->(s) { :next }
      graph.add_conditional_edges(:a, cond)
      expect(graph.conditional_edges[:a][:condition]).to be(cond)
    end

    it "allows omitting the mapping" do
      graph.add_conditional_edges(:a, ->(s) { :next })
      expect(graph.conditional_edges[:a][:mapping]).to be_nil
    end
  end

  describe "#set_entry_point" do
    it "sets the entry point" do
      graph.set_entry_point(:start)
      expect(graph.entry_point).to eq(:start)
    end
  end

  describe "#compile" do
    before do
      graph.add_node(:a) { |s| {value: 1} }
      graph.set_entry_point(:a)
    end

    it "returns a CompiledGraph" do
      expect(graph.compile).to be_a(Phronomy::Graph::CompiledGraph)
    end

    it "uses the first node as entry point when none is set" do
      g = described_class.new(TestState)
      g.add_node(:first) { |s| {} }
      g.add_node(:second) { |s| {} }
      # set_entry_point was not called: expect ArgumentError for multi-node graphs
      expect { g.compile }.to raise_error(ArgumentError, /set_entry_point/)
    end
  end
end

RSpec.describe Phronomy::Graph::CompiledGraph do
  # Create a simple 2-node graph as a shared helper
  def build_graph(&add_nodes)
    g = Phronomy::Graph::StateGraph.new(TestState)
    add_nodes.call(g)
    g.compile
  end

  describe "#invoke" do
    it "executes nodes in order and returns the final state" do
      compiled = build_graph do |g|
        g.add_node(:double) { |s| {value: s.value * 2} }
        g.add_node(:increment) { |s| {value: s.value + 1} }
        g.add_edge(:double, :increment)
        g.set_entry_point(:double)
      end

      result = compiled.invoke({value: 3})
      expect(result.value).to eq(7)  # 3*2+1
    end

    it "accumulates values in append fields" do
      compiled = build_graph do |g|
        g.add_node(:a) { |s| {messages: ["from_a"]} }
        g.add_node(:b) { |s| {messages: ["from_b"]} }
        g.add_edge(:a, :b)
        g.set_entry_point(:a)
      end

      result = compiled.invoke({messages: []})
      expect(result.messages).to eq(["from_a", "from_b"])
    end

    it "returns a State instance" do
      compiled = build_graph do |g|
        g.add_node(:noop) { |s| {} }
        g.set_entry_point(:noop)
      end

      expect(compiled.invoke({})).to be_a(TestState)
    end

    it "accepts a State instance returned from a node" do
      compiled = build_graph do |g|
        g.add_node(:double) { |s| s.merge(value: s.value * 2) }
        g.set_entry_point(:double)
      end

      expect(compiled.invoke({value: 4}).value).to eq(8)
    end

    it "treats a nil return as no-op" do
      compiled = build_graph do |g|
        g.add_node(:noop) { |_s| nil }
        g.set_entry_point(:noop)
      end

      expect(compiled.invoke({value: 7}).value).to eq(7)
    end

    it "raises ArgumentError when a node returns an unsupported type" do
      compiled = build_graph do |g|
        g.add_node(:bad) { |_s| "oops" }
        g.set_entry_point(:bad)
      end

      expect { compiled.invoke({}) }.to raise_error(ArgumentError, /returned String/)
    end

    context "with conditional edges" do
      it "selects the next node based on the condition return value" do
        compiled = build_graph do |g|
          g.add_node(:check) { |s| {step: (s.value > 5) ? :high : :low} }
          g.add_node(:high) { |s| {value: 100} }
          g.add_node(:low) { |s| {value: 0} }
          g.add_conditional_edges(:check, ->(s) { s.step })
          g.set_entry_point(:check)
        end

        expect(compiled.invoke({value: 10}).value).to eq(100)
        expect(compiled.invoke({value: 1}).value).to eq(0)
      end

      it "maps node names using the mapping" do
        compiled = build_graph do |g|
          g.add_node(:check) { |s| {step: "done"} }
          g.add_node(:finish) { |s| {value: 999} }
          g.add_conditional_edges(
            :check,
            ->(s) { s.step },
            {"done" => :finish}
          )
          g.set_entry_point(:check)
        end

        expect(compiled.invoke({}).value).to eq(999)
      end

      it "terminates the graph when END is returned" do
        compiled = build_graph do |g|
          g.add_node(:check) { |s| {value: 42} }
          g.add_conditional_edges(
            :check,
            ->(_s) { Phronomy::Graph::StateGraph::FINISH }
          )
          g.set_entry_point(:check)
        end

        expect(compiled.invoke({}).value).to eq(42)
      end

      # Regression test for issue #42:
      # An unmapped conditional-edge result must raise ArgumentError, not silently
      # terminate the graph and return intermediate (incomplete) state.
      it "raises ArgumentError when the condition returns a key absent from the mapping" do
        compiled = build_graph do |g|
          g.add_node(:router) { |s| {step: "unknown_route"} }
          g.add_node(:path_a) { |s| {value: 999} }
          g.add_conditional_edges(
            :router,
            ->(s) { s.step },
            {"path_a" => :path_a}
          )
          g.add_edge(:path_a, Phronomy::Graph::StateGraph::FINISH)
          g.set_entry_point(:router)
        end

        expect { compiled.invoke({}) }.to raise_error(
          ArgumentError, /unknown_route/
        )
      end
    end

    context "with guard-condition edges" do
      it "takes the first edge whose condition is truthy" do
        compiled = build_graph do |g|
          g.add_node(:check) { |s| s }
          g.add_node(:high) { |s| {value: 100} }
          g.add_node(:low) { |s| {value: 0} }
          g.add_edge(:check, :high, ->(s) { s.value > 5 })
          g.add_edge(:check, :low)
          g.set_entry_point(:check)
        end

        expect(compiled.invoke({value: 10}).value).to eq(100)
        expect(compiled.invoke({value: 3}).value).to eq(0)
      end

      it "skips edges whose condition is falsy" do
        compiled = build_graph do |g|
          g.add_node(:check) { |s| s }
          g.add_node(:a) { |s| {value: 1} }
          g.add_node(:b) { |s| {value: 2} }
          g.add_node(:c) { |s| {value: 3} }
          g.add_edge(:check, :a, ->(s) { s.value == 10 })
          g.add_edge(:check, :b, ->(s) { s.value == 5 })
          g.add_edge(:check, :c)
          g.set_entry_point(:check)
        end

        expect(compiled.invoke({value: 5}).value).to eq(2)  # second edge matches
        expect(compiled.invoke({value: 0}).value).to eq(3)  # unconditional fallback
      end

      it "terminates via a guard-condition edge to FINISH" do
        compiled = build_graph do |g|
          g.add_node(:check) { |s| {value: 42} }
          g.add_edge(:check, Phronomy::Graph::StateGraph::FINISH)
          g.set_entry_point(:check)
        end

        expect(compiled.invoke({}).value).to eq(42)
      end
    end

    context "thread_id" do
      it "auto-assigns a thread_id when not supplied" do
        compiled = build_graph do |g|
          g.add_node(:noop) { |s| {} }
          g.set_entry_point(:noop)
        end
        result = compiled.invoke({})
        expect(result.thread_id).to be_a(String)
        expect(result.thread_id).not_to be_empty
      end

      it "uses the thread_id supplied in config" do
        compiled = build_graph do |g|
          g.add_node(:noop) { |s| {} }
          g.set_entry_point(:noop)
        end
        result = compiled.invoke({}, config: {thread_id: "custom-id"})
        expect(result.thread_id).to eq("custom-id")
      end

      it "current_nodes is empty after normal completion" do
        compiled = build_graph do |g|
          g.add_node(:noop) { |s| {} }
          g.set_entry_point(:noop)
        end
        result = compiled.invoke({})
        expect(result.current_nodes).to eq([])
      end
    end

    context "recursion limit" do
      it "raises RecursionLimitError when recursion_limit is exceeded" do
        compiled = build_graph do |g|
          g.add_node(:loop) { |s| {value: s.value + 1} }
          g.add_edge(:loop, :loop)
          g.set_entry_point(:loop)
        end

        expect {
          compiled.invoke({value: 0}, config: {recursion_limit: 5})
        }.to raise_error(Phronomy::RecursionLimitError)
      end
    end

    context "interrupt_before callback" do
      it "halts before the node when callback returns :halt" do
        compiled = build_graph do |g|
          g.add_node(:dangerous) { |s| {value: 99} }
          g.set_entry_point(:dangerous)
        end
        compiled.interrupt_before(:dangerous) { |_s| :halt }

        result = compiled.invoke({value: 0})
        expect(result.value).to eq(0)             # node did not execute
        expect(result.current_nodes).to eq([:dangerous])
        expect(result.halted_before).to be(true)
      end

      it "continues when callback does not return :halt" do
        compiled = build_graph do |g|
          g.add_node(:safe) { |s| {value: 99} }
          g.set_entry_point(:safe)
        end
        compiled.interrupt_before(:safe) { |_s| nil }

        result = compiled.invoke({value: 0})
        expect(result.value).to eq(99)
        expect(result.current_nodes).to eq([])
      end
    end

    context "interrupt_after callback" do
      it "halts after the node when callback returns :halt" do
        compiled = build_graph do |g|
          g.add_node(:step1) { |s| {value: 10} }
          g.add_node(:step2) { |s| {value: 20} }
          g.add_edge(:step1, :step2)
          g.set_entry_point(:step1)
        end
        compiled.interrupt_after(:step1) { |_s| :halt }

        result = compiled.invoke({value: 0})
        expect(result.value).to eq(10)            # step1 ran, step2 did not
        expect(result.current_nodes).to eq([:step2])
        expect(result.halted_before).to be(false)
      end
    end

    context "with a nonexistent node" do
      it "raises ArgumentError when an edge points to a nonexistent node" do
        compiled = build_graph do |g|
          g.add_node(:start) { |s| {} }
          g.add_edge(:start, :nonexistent)
          g.set_entry_point(:start)
        end

        expect { compiled.invoke({}) }.to raise_error(ArgumentError, /Node nonexistent/)
      end
    end
  end

  describe "#resume" do
    it "resumes from a halted interrupt_before state" do
      compiled = build_graph do |g|
        g.add_node(:step1) { |s| {value: 10} }
        g.add_node(:step2) { |s| {value: s.value + 5} }
        g.add_edge(:step1, :step2)
        g.set_entry_point(:step1)
      end
      compiled.interrupt_before(:step2) { |_s| :halt }

      halted = compiled.invoke({value: 0})
      expect(halted.value).to eq(10)
      expect(halted.current_nodes).to eq([:step2])

      final = compiled.resume(state: halted)
      expect(final.value).to eq(15)
      expect(final.current_nodes).to eq([])
    end

    it "resumes from a halted interrupt_after state" do
      compiled = build_graph do |g|
        g.add_node(:step1) { |s| {value: 10} }
        g.add_node(:step2) { |s| {value: 20} }
        g.add_edge(:step1, :step2)
        g.set_entry_point(:step1)
      end
      compiled.interrupt_after(:step1) { |_s| :halt }

      halted = compiled.invoke({value: 0})
      expect(halted.value).to eq(10)
      expect(halted.current_nodes).to eq([:step2])

      final = compiled.resume(state: halted)
      expect(final.value).to eq(20)
      expect(final.current_nodes).to eq([])
    end

    it "merges additional input before resuming" do
      compiled = build_graph do |g|
        g.add_node(:draft) { |s| {step: :draft_done} }
        g.add_node(:send) { |s| {value: s.value} }
        g.add_edge(:draft, :send)
        g.set_entry_point(:draft)
      end
      compiled.interrupt_before(:send) { |_s| :halt }

      halted = compiled.invoke({value: 0})
      final = compiled.resume(state: halted, input: {value: 42})
      expect(final.value).to eq(42)
    end

    it "raises ArgumentError when state has no current_nodes" do
      compiled = build_graph do |g|
        g.add_node(:noop) { |s| {} }
        g.set_entry_point(:noop)
      end
      finished = compiled.invoke({})
      expect { compiled.resume(state: finished) }.to raise_error(ArgumentError, /pending nodes/)
    end
  end

  describe "#send_event" do
    let(:compiled) do
      build_graph do |g|
        g.add_node(:propose) { |s| {value: "proposed"} }
        g.add_node(:run) { |s| {value: s.value + "_run"} }
        g.set_entry_point(:propose)
        g.add_wait_state(:awaiting_run, resume_event: :approve, after: :propose, before: :run)
        g.add_edge(:run, Phronomy::Graph::StateGraph::FINISH)
      end
    end

    it "resumes from the wait state and completes the graph" do
      halted = compiled.invoke({})
      expect(halted.phase).to eq(:awaiting_run)
      expect(halted.halted?).to be(true)

      final = compiled.send_event(state: halted, event: :approve)
      expect(final.value).to eq("proposed_run")
      expect(final.halted?).to be(false)
      expect(final.phase).to eq(:__end__)
    end

    it "passes optional input to the resumed execution" do
      halted = compiled.invoke({})
      final = compiled.send_event(state: halted, event: :approve, input: {value: "override"})
      expect(final.value).to eq("override_run")
    end

    it "raises ArgumentError for an unknown event" do
      halted = compiled.invoke({})
      expect {
        compiled.send_event(state: halted, event: :nonexistent)
      }.to raise_error(ArgumentError, /Unknown event/)
    end
  end

  describe "#stream" do
    it "yields a { node:, state: } event after each node completes" do
      compiled = build_graph do |g|
        g.add_node(:a) { |s| {value: 1} }
        g.add_node(:b) { |s| {value: 2} }
        g.add_edge(:a, :b)
        g.set_entry_point(:a)
      end

      events = []
      compiled.stream({}) { |e| events << e }

      expect(events.map { |e| e[:node] }).to eq([:a, :b])
      expect(events.last[:state].value).to eq(2)
    end
  end

  describe "#add_wait_state" do
    let(:graph) { Phronomy::Graph::StateGraph.new(TestState) }

    it "adds a wait state and registers the edge from after: to the wait state" do
      graph.add_node(:propose) { |s| s }
      graph.add_node(:run) { |s| s }
      graph.add_wait_state(:awaiting_run, resume_event: :approve, after: :propose, before: :run)
      graph.set_entry_point(:propose)

      expect(graph.edges[:propose].map { |e| e[:to] }).to include(:awaiting_run)
    end

    it "returns self for chaining" do
      graph.add_node(:a) { |s| s }
      graph.add_node(:b) { |s| s }
      result = graph.add_wait_state(:awaiting_b, resume_event: :go, after: :a, before: :b)
      expect(result).to be(graph)
    end
  end

  describe "as a Runnable" do
    it "batch runs the graph for multiple independent initial states" do
      compiled = build_graph do |g|
        g.add_node(:double) { |s| {value: s.value * 2} }
        g.set_entry_point(:double)
      end

      results = compiled.batch([{value: 2}, {value: 3}, {value: 4}])
      expect(results.map(&:value)).to eq([4, 6, 8])
    end
  end
end

# Regression tests for issue #43:
# StateGraph#add_subgraph must use a namespaced child thread_id
# ("parent_id/node_name") so that parent and child checkpoints never collide
# in a shared StateStore.
RSpec.describe "StateGraph#add_subgraph thread_id namespacing (issue #43)" do
  # Simple state class for the parent graph
  class ParentIssue43State
    include Phronomy::Graph::Context

    field :output, type: :replace, default: nil
  end

  # Simple state class for the child graph
  class ChildIssue43State
    include Phronomy::Graph::Context

    field :sub_result, type: :replace, default: nil
  end

  it "saves the child checkpoint under a namespaced thread_id, not the parent thread_id" do
    store = Phronomy::StateStore::InMemory.new

    # Build and compile the child graph
    sub_graph = Phronomy::Graph::StateGraph.new(ChildIssue43State)
    sub_graph.add_node(:sub_step) { |s| s.merge(sub_result: "sub done") }
    sub_graph.set_entry_point(:sub_step)
    sub_compiled = sub_graph.compile(state_store: store)

    # Build and compile the parent graph, embedding the child as a subgraph
    parent_graph = Phronomy::Graph::StateGraph.new(ParentIssue43State)
    parent_graph.add_subgraph(:child, sub_compiled)
    parent_graph.add_node(:final) { |s| s.merge(output: "parent done") }
    parent_graph.set_entry_point(:child)
    parent_graph.add_edge(:child, :final)
    parent_graph.add_edge(:final, Phronomy::Graph::StateGraph::FINISH)
    parent_compiled = parent_graph.compile(state_store: store)

    parent_compiled.invoke({}, config: {thread_id: "t1"})

    # The parent checkpoint must be a ParentIssue43State
    parent_checkpoint = store.load("t1")
    expect(parent_checkpoint).to be_a(ParentIssue43State),
      "expected ParentIssue43State at key 't1', got #{parent_checkpoint.class}"

    # The child checkpoint must be saved under the namespaced key
    child_checkpoint = store.load("t1/child")
    expect(child_checkpoint).to be_a(ChildIssue43State),
      "expected ChildIssue43State at key 't1/child', got #{child_checkpoint.inspect}"
  end
end
