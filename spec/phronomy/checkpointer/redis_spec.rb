# frozen_string_literal: true

require "spec_helper"

# ---------------------------------------------------------------------------
# Minimal Redis client stub — mimics redis-rb key/value operations.
# ---------------------------------------------------------------------------
class FakeRedisClient
  def initialize
    @store = {}
  end

  def set(key, value, ex: nil)
    @store[key] = {value: value, ex: ex}
    "OK"
  end

  def get(key)
    entry = @store[key]
    return nil unless entry
    entry[:value]
  end

  def del(key)
    @store.delete(key) ? 1 : 0
  end

  def ttl_set?(key)
    entry = @store[key]
    entry && !entry[:ex].nil?
  end
end

# State class used throughout these specs.
class RedisCheckpointState
  include Phronomy::Graph::State
  field :count,    type: :replace, default: 0
  field :label,    type: :replace, default: nil
  field :messages, type: :append,  default: -> { [] }
end

RSpec.describe Phronomy::Checkpointer::Redis do
  let(:redis_client) { FakeRedisClient.new }
  subject(:cp)       { described_class.new(client: redis_client) }

  let(:state) { RedisCheckpointState.new(count: 5, label: "active") }

  # ---- .new ------------------------------------------------------------------

  describe ".new" do
    it "accepts a client and an optional ttl" do
      with_ttl = described_class.new(client: redis_client, ttl: 600)
      expect(with_ttl).to be_a(described_class)
    end
  end

  # ---- #save / #load ---------------------------------------------------------

  describe "#save / #load" do
    it "persists state and restores it with correct field values" do
      cp.save("t1", state)
      loaded = cp.load("t1")
      expect(loaded.state.count).to eq(5)
      expect(loaded.state.label).to eq("active")
    end

    it "stores interrupted_at as a Symbol" do
      cp.save("t1", state, interrupted_at: :step_one)
      expect(cp.load("t1").interrupted_at).to eq(:step_one)
    end

    it "stores completed_node as a Symbol" do
      cp.save("t1", state, completed_node: :step_two)
      expect(cp.load("t1").completed_node).to eq(:step_two)
    end

    it "returns self for method chaining" do
      expect(cp.save("t1", state)).to be(cp)
    end

    it "returns nil for an unknown thread_id" do
      expect(cp.load("missing")).to be_nil
    end

    it "overwrites an existing checkpoint on re-save" do
      cp.save("t1", state)
      cp.save("t1", RedisCheckpointState.new(count: 99))
      expect(cp.load("t1").state.count).to eq(99)
    end

    it "manages multiple threads independently" do
      cp.save("t1", RedisCheckpointState.new(count: 1))
      cp.save("t2", RedisCheckpointState.new(count: 2))
      expect(cp.load("t1").state.count).to eq(1)
      expect(cp.load("t2").state.count).to eq(2)
    end

    it "reconstructs the correct state class" do
      cp.save("t1", state)
      expect(cp.load("t1").state).to be_a(RedisCheckpointState)
    end

    it "serializes state containing RubyLLM::ToolCall objects without raising" do
      tc = RubyLLM::ToolCall.new(id: "call_1", name: "get_time", arguments: {})
      msg = OpenStruct.new(role: :assistant, content: "", tool_calls: {"call_1" => tc})
      state_with_msgs = RedisCheckpointState.new(count: 1, messages: [msg])
      expect { cp.save("t1", state_with_msgs) }.not_to raise_error
    end

    it "round-trips state with RubyLLM::ToolCall — messages field is an Array" do
      tc = RubyLLM::ToolCall.new(id: "call_1", name: "get_time", arguments: {})
      msg = OpenStruct.new(role: :assistant, content: "", tool_calls: {"call_1" => tc})
      state_with_msgs = RedisCheckpointState.new(count: 7, messages: [msg])
      cp.save("t1", state_with_msgs)

      loaded = cp.load("t1")
      expect(loaded.state.count).to eq(7)
      expect(loaded.state.messages).to be_an(Array)
    end

    it "uses the key prefix 'phronomy:checkpoint:'" do
      cp.save("t1", state)
      raw = redis_client.get("phronomy:checkpoint:t1")
      expect(raw).not_to be_nil
    end
  end

  # ---- TTL -------------------------------------------------------------------

  describe "TTL support" do
    it "sets the expiry when ttl is specified" do
      cp_with_ttl = described_class.new(client: redis_client, ttl: 300)
      cp_with_ttl.save("t1", state)
      expect(redis_client.ttl_set?("phronomy:checkpoint:t1")).to be true
    end

    it "does not set an expiry when no ttl is specified" do
      cp.save("t1", state)
      expect(redis_client.ttl_set?("phronomy:checkpoint:t1")).to be false
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

    it "does not raise when clearing a non-existent thread" do
      expect { cp.clear("ghost") }.not_to raise_error
    end
  end

  # ---- Checkpoint struct fields ----------------------------------------------

  describe "Checkpoint struct" do
    before { cp.save("t1", state, interrupted_at: :node_x, completed_node: :node_y) }

    subject(:checkpoint) { cp.load("t1") }

    it "exposes state" do
      expect(checkpoint.state).to be_a(RedisCheckpointState)
    end

    it "exposes interrupted_at" do
      expect(checkpoint.interrupted_at).to eq(:node_x)
    end

    it "exposes completed_node" do
      expect(checkpoint.completed_node).to eq(:node_y)
    end
  end
end
