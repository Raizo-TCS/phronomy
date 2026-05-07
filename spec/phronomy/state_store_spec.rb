# frozen_string_literal: true

require "spec_helper"

# State class for testing
class StoreTestState
  include Phronomy::Graph::State

  field :value, type: :replace, default: 0
end

def make_state(value:, thread_id: "t1", current_nodes: [], halted_before: false)
  s = StoreTestState.new(value: value)
  s.set_graph_metadata(thread_id: thread_id, current_nodes: current_nodes, halted_before: halted_before)
  s
end

RSpec.describe Phronomy::StateStore::Base do
  subject(:store) { described_class.new }

  it "raises NotImplementedError for save" do
    expect { store.save(make_state(value: 1)) }.to raise_error(NotImplementedError)
  end

  it "raises NotImplementedError for load" do
    expect { store.load("t1") }.to raise_error(NotImplementedError)
  end

  it "raises NotImplementedError for clear" do
    expect { store.clear("t1") }.to raise_error(NotImplementedError)
  end
end

RSpec.describe Phronomy::StateStore::InMemory do
  subject(:store) { described_class.new }

  describe "#save / #load" do
    it "saves and retrieves state by thread_id" do
      state = make_state(value: 42, thread_id: "t1")
      store.save(state)
      loaded = store.load("t1")
      expect(loaded.value).to eq(42)
    end

    it "preserves thread_id in loaded state" do
      state = make_state(value: 1, thread_id: "mythread")
      store.save(state)
      expect(store.load("mythread").thread_id).to eq("mythread")
    end

    it "preserves current_nodes in loaded state" do
      state = make_state(value: 1, thread_id: "t1", current_nodes: [:send], halted_before: true)
      store.save(state)
      loaded = store.load("t1")
      expect(loaded.current_nodes).to eq([:send])
      expect(loaded.halted_before).to be(true)
    end

    it "save returns self for chaining" do
      expect(store.save(make_state(value: 1, thread_id: "t1"))).to be(store)
    end

    it "returns nil for unknown thread_id" do
      expect(store.load("unknown")).to be_nil
    end

    it "manages multiple threads independently" do
      store.save(make_state(value: 1, thread_id: "t1"))
      store.save(make_state(value: 2, thread_id: "t2"))
      expect(store.load("t1").value).to eq(1)
      expect(store.load("t2").value).to eq(2)
    end

    it "overwrites an existing state on re-save" do
      store.save(make_state(value: 1, thread_id: "t1"))
      store.save(make_state(value: 99, thread_id: "t1"))
      expect(store.load("t1").value).to eq(99)
    end
  end

  describe "#clear" do
    it "removes the state for the given thread_id" do
      store.save(make_state(value: 1, thread_id: "t1"))
      store.clear("t1")
      expect(store.load("t1")).to be_nil
    end

    it "clear returns self for chaining" do
      store.save(make_state(value: 1, thread_id: "t1"))
      expect(store.clear("t1")).to be(store)
    end

    it "does not affect other threads" do
      store.save(make_state(value: 1, thread_id: "t1"))
      store.save(make_state(value: 2, thread_id: "t2"))
      store.clear("t1")
      expect(store.load("t2").value).to eq(2)
    end
  end

  describe "#clear_all" do
    it "removes all stored states" do
      store.save(make_state(value: 1, thread_id: "t1"))
      store.save(make_state(value: 2, thread_id: "t2"))
      store.clear_all
      expect(store.load("t1")).to be_nil
      expect(store.load("t2")).to be_nil
    end
  end
end

RSpec.describe "CompiledGraph and StateStore integration" do
  def build_compiled
    g = Phronomy::Graph::StateGraph.new(StoreTestState)
    g.add_node(:step1) { |s| {value: s.value + 10} }
    g.add_node(:step2) { |s| {value: s.value + 1} }
    g.add_edge(:step1, :step2)
    g.set_entry_point(:step1)
    g.compile
  end

  around do |example|
    Phronomy.configure { |c| c.default_state_store = Phronomy::StateStore::InMemory.new }
    example.run
    Phronomy.reset_configuration!
  end

  it "saves final state to store after normal completion" do
    compiled = build_compiled
    result = compiled.invoke({value: 0})
    store = Phronomy.configuration.default_state_store
    saved = store.load(result.thread_id)
    expect(saved).not_to be_nil
    expect(saved.value).to eq(11)
  end

  it "saves halted state to store on interrupt_before" do
    compiled = build_compiled
    compiled.interrupt_before(:step2) { |_s| :halt }
    halted = compiled.invoke({value: 0})

    store = Phronomy.configuration.default_state_store
    saved = store.load(halted.thread_id)
    expect(saved.current_nodes).to eq([:step2])
    expect(saved.halted_before).to be(true)
  end

  it "resumes and completes, then stores final state" do
    compiled = build_compiled
    compiled.interrupt_before(:step2) { |_s| :halt }
    halted = compiled.invoke({value: 0})

    final = compiled.resume(state: halted)
    expect(final.value).to eq(11)
    expect(final.current_nodes).to eq([])
  end
end
