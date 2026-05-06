# frozen_string_literal: true

require "spec_helper"
require_relative "../../support/active_record_setup"

# State class used throughout these specs.
class ArCheckpointState
  include Phronomy::Graph::State
  field :score,    type: :replace, default: 0
  field :label,    type: :replace, default: nil
  field :messages, type: :append,  default: -> { [] }
end

RSpec.describe Phronomy::Checkpointer::ActiveRecord do
  # Use the real PhronomyCheckpointRecord model backed by in-memory SQLite.
  subject(:cp) { described_class.new(model_class: PhronomyCheckpointRecord) }

  # Truncate the table between each example for test isolation.
  before { PhronomyCheckpointRecord.delete_all }

  let(:state) { ArCheckpointState.new(score: 7, label: "done") }

  # ---- #save / #load ---------------------------------------------------------

  describe "#save / #load" do
    it "persists state and restores it with correct field values" do
      cp.save("t1", state)
      loaded = cp.load("t1")
      expect(loaded.state.score).to eq(7)
      expect(loaded.state.label).to eq("done")
    end

    it "stores interrupted_at as a Symbol" do
      cp.save("t1", state, interrupted_at: :node_a)
      expect(cp.load("t1").interrupted_at).to eq(:node_a)
    end

    it "stores completed_node as a Symbol" do
      cp.save("t1", state, completed_node: :node_b)
      expect(cp.load("t1").completed_node).to eq(:node_b)
    end

    it "returns self for method chaining" do
      expect(cp.save("t1", state)).to be(cp)
    end

    it "returns nil for an unknown thread_id" do
      expect(cp.load("missing")).to be_nil
    end

    it "overwrites an existing checkpoint on re-save" do
      cp.save("t1", state)
      cp.save("t1", ArCheckpointState.new(score: 99))
      expect(cp.load("t1").state.score).to eq(99)
    end

    it "manages multiple threads independently" do
      cp.save("t1", ArCheckpointState.new(score: 1))
      cp.save("t2", ArCheckpointState.new(score: 2))
      expect(cp.load("t1").state.score).to eq(1)
      expect(cp.load("t2").state.score).to eq(2)
    end

    it "reconstructs the correct state class" do
      cp.save("t1", state)
      expect(cp.load("t1").state).to be_a(ArCheckpointState)
    end

    it "serializes state containing RubyLLM::ToolCall objects without raising" do
      tc = RubyLLM::ToolCall.new(id: "call_1", name: "get_time", arguments: {})
      msg = OpenStruct.new(role: :assistant, content: "", tool_calls: {"call_1" => tc})
      state_with_msgs = ArCheckpointState.new(score: 1, messages: [msg])
      expect { cp.save("t1", state_with_msgs) }.not_to raise_error
    end

    it "round-trips state with RubyLLM::ToolCall — messages field is an Array" do
      tc = RubyLLM::ToolCall.new(id: "call_1", name: "get_time", arguments: {})
      msg = OpenStruct.new(role: :assistant, content: "", tool_calls: {"call_1" => tc})
      state_with_msgs = ArCheckpointState.new(score: 42, messages: [msg])
      cp.save("t1", state_with_msgs)

      loaded = cp.load("t1")
      expect(loaded.state.score).to eq(42)
      expect(loaded.state.messages).to be_an(Array)
      expect(loaded.state.messages.first).to be_a(Hash)
    end
  end

  # ---- #clear ----------------------------------------------------------------

  describe "#clear" do
    it "removes the checkpoint for the given thread_id" do
      cp.save("t1", state)
      cp.clear("t1")
      expect(cp.load("t1")).to be_nil
    end

    it "returns self for method chaining" do
      cp.save("t1", state)
      expect(cp.clear("t1")).to be(cp)
    end

    it "does not affect other threads" do
      cp.save("t1", state)
      cp.save("t2", ArCheckpointState.new(score: 5))
      cp.clear("t1")
      expect(cp.load("t2").state.score).to eq(5)
    end
  end
end
