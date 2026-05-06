# frozen_string_literal: true

require "spec_helper"

# State class for testing
class CheckpointState
  include Phronomy::Graph::State
  field :value, type: :replace, default: 0
end

RSpec.describe Phronomy::Checkpointer::Base do
  subject(:cp) { described_class.new }

  it "raises NotImplementedError for save" do
    expect { cp.save("t1", double) }.to raise_error(NotImplementedError)
  end

  it "raises NotImplementedError for load" do
    expect { cp.load("t1") }.to raise_error(NotImplementedError)
  end

  it "raises NotImplementedError for clear" do
    expect { cp.clear("t1") }.to raise_error(NotImplementedError)
  end
end

RSpec.describe Phronomy::Checkpointer::InMemory do
  subject(:cp) { described_class.new }

  let(:state) { CheckpointState.new(value: 42) }

  describe "#save / #load" do
    it "saves and retrieves state" do
      cp.save("t1", state)
      checkpoint = cp.load("t1")
      expect(checkpoint.state.value).to eq(42)
    end

    it "saves interrupted_at" do
      cp.save("t1", state, interrupted_at: :node_a)
      expect(cp.load("t1").interrupted_at).to eq(:node_a)
    end

    it "saves completed_node" do
      cp.save("t1", state, completed_node: :node_b)
      expect(cp.load("t1").completed_node).to eq(:node_b)
    end

    it "save returns self for chaining" do
      expect(cp.save("t1", state)).to be(cp)
    end

    it "returns nil for unknown thread_id" do
      expect(cp.load("unknown")).to be_nil
    end

    it "manages multiple threads independently" do
      s1 = CheckpointState.new(value: 1)
      s2 = CheckpointState.new(value: 2)
      cp.save("t1", s1)
      cp.save("t2", s2)
      expect(cp.load("t1").state.value).to eq(1)
      expect(cp.load("t2").state.value).to eq(2)
    end

    it "overwrites an existing checkpoint on re-save" do
      cp.save("t1", state)
      new_state = CheckpointState.new(value: 99)
      cp.save("t1", new_state)
      expect(cp.load("t1").state.value).to eq(99)
    end
  end

  describe "#clear" do
    it "removes the checkpoint for the given thread_id" do
      cp.save("t1", state)
      cp.clear("t1")
      expect(cp.load("t1")).to be_nil
    end

    it "clear returns self for chaining" do
      cp.save("t1", state)
      expect(cp.clear("t1")).to be(cp)
    end

    it "does not affect other threads" do
      s2 = CheckpointState.new(value: 7)
      cp.save("t1", state)
      cp.save("t2", s2)
      cp.clear("t1")
      expect(cp.load("t2").state.value).to eq(7)
    end
  end

  describe "#clear_all" do
    it "removes all checkpoints" do
      cp.save("t1", state)
      cp.save("t2", state)
      cp.clear_all
      expect(cp.load("t1")).to be_nil
      expect(cp.load("t2")).to be_nil
    end
  end
end

RSpec.describe "CompiledGraph and Checkpointer integration" do
  let(:checkpointer) { Phronomy::Checkpointer::InMemory.new }

  def build_compiled(checkpointer: nil, interrupt_before: [], interrupt_after: [])
    g = Phronomy::Graph::StateGraph.new(CheckpointState)
    g.add_node(:step1) { |s| {value: s.value + 10} }
    g.add_node(:step2) { |s| {value: s.value + 1} }
    g.add_edge(:step1, :step2)
    g.set_entry_point(:step1)
    g.compile(checkpointer: checkpointer, interrupt_before: interrupt_before, interrupt_after: interrupt_after)
  end

  it "saves state after each node when checkpointer is configured" do
    compiled = build_compiled(checkpointer: checkpointer)
    compiled.invoke({value: 0}, config: {thread_id: "t1"})
    checkpoint = checkpointer.load("t1")
    expect(checkpoint).not_to be_nil
    expect(checkpoint.state.value).to eq(11)
  end

  it "saves interrupted state to checkpointer when interrupt_before fires" do
    compiled = build_compiled(checkpointer: checkpointer, interrupt_before: [:step2])
    expect {
      compiled.invoke({value: 0}, config: {thread_id: "t1"})
    }.to raise_error(Phronomy::Interrupt)

    checkpoint = checkpointer.load("t1")
    expect(checkpoint).not_to be_nil
    expect(checkpoint.interrupted_at).to eq(:step2)
  end

  describe "#resume" do
    it "continues from the interrupted node and returns the final state" do
      compiled = build_compiled(checkpointer: checkpointer, interrupt_before: [:step2])
      expect {
        compiled.invoke({value: 0}, config: {thread_id: "t1"})
      }.to raise_error(Phronomy::Interrupt)

      result = compiled.resume(thread_id: "t1")
      expect(result.value).to eq(11) # step1 ran before interrupt (+10), step2 ran on resume (+1)
    end

    it "does not re-raise Interrupt for the resumed node" do
      compiled = build_compiled(checkpointer: checkpointer, interrupt_before: [:step2])
      expect { compiled.invoke({value: 0}, config: {thread_id: "t1"}) }.to raise_error(Phronomy::Interrupt)
      expect { compiled.resume(thread_id: "t1") }.not_to raise_error
    end

    it "merges additional input when provided" do
      compiled = build_compiled(checkpointer: checkpointer, interrupt_before: [:step2])
      expect { compiled.invoke({value: 0}, config: {thread_id: "t1"}) }.to raise_error(Phronomy::Interrupt)
      result = compiled.resume(thread_id: "t1", input: {value: 100})
      expect(result.value).to eq(101) # override to 100, then step2 (+1) = 101
    end

    it "raises ArgumentError when no checkpointer is configured" do
      compiled = build_compiled # no checkpointer
      expect { compiled.resume(thread_id: "t1") }.to raise_error(ArgumentError, /Checkpointer/)
    end

    it "raises ArgumentError when no checkpoint exists for the thread" do
      compiled = build_compiled(checkpointer: checkpointer)
      expect { compiled.resume(thread_id: "missing") }.to raise_error(ArgumentError, /missing/)
    end
  end
end
