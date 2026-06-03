# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::Checkpoint do
  # Helpers to build fixture messages

  def user_message(text)
    RubyLLM::Message.new(role: :user, content: text)
  end

  def assistant_message(text)
    RubyLLM::Message.new(role: :assistant, content: text)
  end

  def tool_call_message(call_id:, tool_name:, args: {})
    tc = RubyLLM::ToolCall.new(id: call_id, name: tool_name, arguments: args)
    RubyLLM::Message.new(role: :assistant, content: "", tool_calls: [tc])
  end

  def checkpoint(messages: [], **overrides)
    defaults = {
      thread_id: "thread-1",
      original_input: "Do task X",
      messages: messages,
      pending_tool_name: "my_tool",
      pending_tool_args: {x: 1},
      pending_tool_call_id: "call_abc"
    }
    described_class.new(**defaults.merge(overrides))
  end

  # ---------------------------------------------------------------------------
  # #to_h
  # ---------------------------------------------------------------------------
  describe "#to_h" do
    it "returns a Hash with expected top-level keys" do
      h = checkpoint.to_h
      expect(h.keys).to match_array(%i[
        checkpoint_id agent_class requested_at
        thread_id original_input messages
        pending_tool_name pending_tool_args pending_tool_call_id
      ])
    end

    it "serializes scalar fields directly" do
      h = checkpoint(
        thread_id: "t99",
        pending_tool_name: "calc",
        pending_tool_args: {n: 42},
        pending_tool_call_id: "call_xyz"
      ).to_h
      expect(h[:thread_id]).to eq("t99")
      expect(h[:pending_tool_name]).to eq("calc")
      expect(h[:pending_tool_args]).to eq({n: 42})
      expect(h[:pending_tool_call_id]).to eq("call_xyz")
    end

    context "when messages contain only plain text" do
      it "serializes each message as a Hash" do
        msgs = [user_message("hello"), assistant_message("hi")]
        h = checkpoint(messages: msgs).to_h
        expect(h[:messages]).to all(be_a(Hash))
      end

      it "preserves role and content" do
        msgs = [user_message("hello")]
        m = checkpoint(messages: msgs).to_h[:messages].first
        expect(m[:role]).to eq(:user)
        expect(m[:content]).to eq("hello")
      end
    end

    context "when a message contains a tool call" do
      it "serializes ToolCall objects to plain hashes" do
        msgs = [tool_call_message(call_id: "call_1", tool_name: "calculator", args: {x: 7})]
        h = checkpoint(messages: msgs).to_h
        tool_calls = h[:messages].first[:tool_calls]
        expect(tool_calls).to be_an(Array)
        expect(tool_calls.first).to be_a(Hash)
        expect(tool_calls.first[:id]).to eq("call_1")
        expect(tool_calls.first[:name]).to eq("calculator")
        expect(tool_calls.first[:arguments]).to eq({x: 7})
      end

      it "contains no RubyLLM::ToolCall objects after serialization" do
        msgs = [tool_call_message(call_id: "c1", tool_name: "t")]
        h = checkpoint(messages: msgs).to_h
        all_values = h[:messages].flat_map(&:values).flatten
        expect(all_values.any? { |v| v.is_a?(RubyLLM::ToolCall) }).to be(false)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # .from_h
  # ---------------------------------------------------------------------------
  describe ".from_h" do
    it "reconstructs a Checkpoint from a Symbol-keyed hash" do
      original = checkpoint
      restored = described_class.from_h(original.to_h)
      expect(restored.thread_id).to eq(original.thread_id)
      expect(restored.pending_tool_name).to eq(original.pending_tool_name)
      expect(restored.pending_tool_args).to eq(original.pending_tool_args)
      expect(restored.pending_tool_call_id).to eq(original.pending_tool_call_id)
    end

    it "reconstructs a Checkpoint from a String-keyed hash (JSON-like)" do
      original = checkpoint
      string_keyed = JSON.parse(JSON.generate(original.to_h))
      restored = described_class.from_h(string_keyed)
      expect(restored).to be_a(described_class)
      expect(restored.thread_id).to eq("thread-1")
    end

    it "reconstructs RubyLLM::Message objects" do
      msgs = [user_message("hello"), assistant_message("hi")]
      original = checkpoint(messages: msgs)
      restored = described_class.from_h(original.to_h)
      expect(restored.messages).to all(be_a(RubyLLM::Message))
      expect(restored.messages.first.role).to eq(:user)
    end

    it "reconstructs RubyLLM::ToolCall objects inside messages" do
      msgs = [tool_call_message(call_id: "call_1", tool_name: "my_tool", args: {n: 5})]
      original = checkpoint(messages: msgs)
      restored = described_class.from_h(original.to_h)
      tc = restored.messages.first.tool_calls.first
      expect(tc).to be_a(RubyLLM::ToolCall)
      expect(tc.id).to eq("call_1")
      expect(tc.name).to eq("my_tool")
      expect(tc.arguments).to eq({n: 5})
    end

    it "accepts nil thread_id" do
      original = checkpoint(thread_id: nil)
      restored = described_class.from_h(original.to_h)
      expect(restored.thread_id).to be_nil
    end

    it "normalizes pending_tool_args keys to symbols" do
      h = checkpoint.to_h
      # Simulate JSON round-trip where string keys arrive for nested hash
      h[:pending_tool_args] = {"x" => 1}
      restored = described_class.from_h(h)
      expect(restored.pending_tool_args.keys).to all(be_a(Symbol))
    end
  end

  # ---------------------------------------------------------------------------
  # Round-trip through JSON
  # ---------------------------------------------------------------------------
  describe "JSON round-trip" do
    it "preserves all fields after to_h -> JSON.generate -> JSON.parse -> from_h" do
      msgs = [
        user_message("plan X"),
        tool_call_message(call_id: "call_z", tool_name: "exec_tool", args: {cmd: "ls"})
      ]
      original = checkpoint(
        thread_id: "t-abc",
        original_input: "plan X",
        messages: msgs,
        pending_tool_name: "exec_tool",
        pending_tool_args: {cmd: "ls"},
        pending_tool_call_id: "call_z"
      )

      json_str = JSON.generate(original.to_h)
      restored = described_class.from_h(JSON.parse(json_str))

      expect(restored.thread_id).to eq("t-abc")
      expect(restored.original_input).to eq("plan X")
      expect(restored.pending_tool_name).to eq("exec_tool")
      expect(restored.pending_tool_call_id).to eq("call_z")
      expect(restored.messages.length).to eq(2)
      expect(restored.messages.first.role).to eq(:user)
      tc = restored.messages.last.tool_calls.first
      expect(tc).to be_a(RubyLLM::ToolCall)
      expect(tc.name).to eq("exec_tool")
    end
  end
end
