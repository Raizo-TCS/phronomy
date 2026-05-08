# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Graph::ParallelNode do
  # Simple append-type state for parallel tests.
  class ParallelTestState
    include Phronomy::Graph::State

    field :a, type: :replace
    field :b, type: :replace
    field :log, type: :append, default: -> { [] }
    field :meta, type: :merge, default: -> { {} }
  end

  let(:state) { ParallelTestState.new }

  describe "#initialize" do
    it "raises ArgumentError when given an empty branches array" do
      expect { described_class.new([]) }.to raise_error(ArgumentError, /non-empty Array/)
    end

    it "accepts a non-empty array of callables" do
      node = described_class.new([->(s) {}])
      expect(node).to be_a(described_class)
    end
  end

  describe "#call" do
    it "returns nil when all branches return nil" do
      node = described_class.new([->(s) {}, ->(s) {}])
      expect(node.call(state)).to be_nil
    end

    it "returns a merged Hash when one branch returns a Hash" do
      node = described_class.new([->(s) { {a: "A"} }])
      result = node.call(state)
      expect(result).to eq({a: "A"})
    end

    it "merges disjoint keys from two branches (replace policy)" do
      node = described_class.new([
        ->(s) { {a: "from_a"} },
        ->(s) { {b: "from_b"} }
      ])
      result = node.call(state)
      expect(result[:a]).to eq("from_a")
      expect(result[:b]).to eq("from_b")
    end

    it "concatenates Array values (append policy)" do
      node = described_class.new([
        ->(s) { {log: ["x"]} },
        ->(s) { {log: ["y"]} }
      ])
      result = node.call(state)
      expect(result[:log]).to contain_exactly("x", "y")
    end

    it "deep-merges Hash values (merge policy)" do
      node = described_class.new([
        ->(s) { {meta: {k1: "v1"}} },
        ->(s) { {meta: {k2: "v2"}} }
      ])
      result = node.call(state)
      expect(result[:meta]).to eq({k1: "v1", k2: "v2"})
    end

    it "uses last-write-wins for scalar conflicts" do
      node = described_class.new([
        ->(s) { {a: "first"} },
        ->(s) { {a: "second"} }
      ])
      result = node.call(state)
      expect(result[:a]).to eq("second")
    end

    it "re-raises exceptions from a branch thread" do
      node = described_class.new(
        [->(s) { raise "branch error" }]
      )
      expect { node.call(state) }.to raise_error(RuntimeError, "branch error")
    end

    it "executes branches concurrently (all run even when ordered)" do
      results = []
      m = Mutex.new
      node = described_class.new([
        ->(s) {
          m.synchronize { results << :a }
          {a: "a"}
        },
        ->(s) {
          m.synchronize { results << :b }
          {b: "b"}
        },
        ->(s) {
          m.synchronize { results << :c }
          nil
        }
      ])
      node.call(state)
      expect(results).to contain_exactly(:a, :b, :c)
    end
  end
end

RSpec.describe "Phronomy::Graph::StateGraph#add_parallel_node" do
  class ParallelGraphState
    include Phronomy::Graph::State

    field :sum, type: :replace, default: 0
    field :parts, type: :append, default: -> { [] }
  end

  it "registers a ParallelNode and executes branches within a compiled graph" do
    graph = Phronomy::Graph::StateGraph.new(ParallelGraphState)
    graph.add_parallel_node(:parallel,
      ->(state) { {parts: ["a"]} },
      ->(state) { {parts: ["b"]} })
    graph.set_entry_point(:parallel)
    graph.add_edge(:parallel, Phronomy::Graph::StateGraph::FINISH)
    app = graph.compile

    final = app.invoke({})
    expect(final.parts).to contain_exactly("a", "b")
  end

  it "raises ArgumentError when no branches are given" do
    graph = Phronomy::Graph::StateGraph.new(ParallelGraphState)
    expect { graph.add_parallel_node(:bad) }.to raise_error(ArgumentError, /at least one branch/)
  end
end

RSpec.describe "Phronomy::Graph::StateGraph#add_subgraph" do
  # Sub-state and parent state share the :result field.
  class SubState
    include Phronomy::Graph::State

    field :value, type: :replace
    field :step, type: :replace, default: 0
  end

  class ParentState
    include Phronomy::Graph::State

    field :value, type: :replace
    field :step, type: :replace, default: 0
    field :extra, type: :replace, default: "parent_extra"
  end

  let(:subgraph) do
    sg = Phronomy::Graph::StateGraph.new(SubState)
    sg.add_node(:sub_a) { |s| {value: "#{s.value}_sub_a", step: s.step + 1} }
    sg.add_node(:sub_b) { |s| {value: "#{s.value}_sub_b", step: s.step + 1} }
    sg.set_entry_point(:sub_a)
    sg.add_edge(:sub_a, :sub_b)
    sg.add_edge(:sub_b, Phronomy::Graph::StateGraph::FINISH)
    sg.compile
  end

  it "executes the subgraph and merges its output into the parent state" do
    parent = Phronomy::Graph::StateGraph.new(ParentState)
    parent.add_subgraph(:nested, subgraph)
    parent.set_entry_point(:nested)
    parent.add_edge(:nested, Phronomy::Graph::StateGraph::FINISH)
    app = parent.compile

    final = app.invoke({value: "start"})
    expect(final.value).to eq("start_sub_a_sub_b")
    expect(final.step).to eq(2)
    # Fields not present in the subgraph output are preserved from parent state.
    expect(final.extra).to eq("parent_extra")
  end

  it "applies input_mapper and output_mapper when provided" do
    parent = Phronomy::Graph::StateGraph.new(ParentState)
    parent.add_subgraph(
      :nested, subgraph,
      input_mapper: ->(state) { {value: "mapped_#{state.value}", step: 0} },
      output_mapper: ->(sub_state) { {value: sub_state.value.upcase} }
    )
    parent.set_entry_point(:nested)
    parent.add_edge(:nested, Phronomy::Graph::StateGraph::FINISH)
    app = parent.compile

    final = app.invoke({value: "init"})
    expect(final.value).to eq("MAPPED_INIT_SUB_A_SUB_B")
  end
end
