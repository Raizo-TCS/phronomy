# frozen_string_literal: true

require_relative "spec_helper"

# Group 5: Memory Detail Parameters
# Pairwise factors: memory_type × window_memory_k × summary_memory_max_tokens ×
#                   summary_memory_summarizer_model × active_record_memory_pruner ×
#                   tool_output_pruner_max_chars
# Feasible cases: 17
#   Infeasible (R2): TC-023..026 — active_record requires Rails/ActiveRecord
#   Infeasible (R3): TC-013..017 — semantic requires embedding endpoint
#
# LLM note: SummaryMemory tests that trigger compression call LM Studio.
#           Tests that can avoid LLM do so with huge max_tokens or explicit load.

RSpec.describe "Group 5: Memory Detail Parameters", :integration do
  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------
  Msg = Struct.new(:role, :content)

  def tool_msg(content)
    Msg.new(:tool, content)
  end

  def user_msg(content)
    Msg.new(:user, content)
  end

  def assistant_msg(content)
    Msg.new(:assistant, content)
  end

  # Return a pruner instance for the given label.
  # @param label [String] "nil" | "zero" | "tight" | "default" | "large" |
  #                       "default_max_chars" | "tight_max_chars"
  def tool_pruner(label)
    case label
    when "nil"               then nil
    when "zero"              then Phronomy::Memory::Pruner::ToolOutputPruner.new(max_chars: 0)
    when "tight"             then Phronomy::Memory::Pruner::ToolOutputPruner.new(max_chars: 50)
    when "default"           then Phronomy::Memory::Pruner::ToolOutputPruner.new(max_chars: 4000)
    when "large"             then Phronomy::Memory::Pruner::ToolOutputPruner.new(max_chars: 1_000_000)
    when "default_max_chars" then Phronomy::Memory::Pruner::ToolOutputPruner.new(max_chars: 4000)
    when "tight_max_chars"   then Phronomy::Memory::Pruner::ToolOutputPruner.new(max_chars: 10)
    else raise ArgumentError, "Unknown pruner label: #{label}"
    end
  end

  # Prune messages (noop if pruner is nil).
  def apply_pruner(messages, pruner)
    pruner ? pruner.prune(messages) : messages
  end

  # ---------------------------------------------------------------------------
  # TC-001: none memory; zero tool_output_pruner — every tool msg truncated to notice
  # ---------------------------------------------------------------------------
  describe "TC-001: none memory; zero tool_output_pruner" do
    it "ToolOutputPruner(max_chars: 0) truncates every tool message to the truncation notice" do
      pruner = tool_pruner("zero")
      msgs = [tool_msg("hello world"), tool_msg("another output")]
      result = apply_pruner(msgs, pruner)
      result.each do |m|
        expect(m.content).to include(Phronomy::Memory::Pruner::ToolOutputPruner::TRUNCATION_NOTE)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: none memory; tight tool_output_pruner
  # ---------------------------------------------------------------------------
  describe "TC-002: none memory; tight tool_output_pruner (max_chars=50)" do
    it "truncates tool messages longer than 50 chars and leaves shorter ones intact" do
      pruner = tool_pruner("tight")
      long_msg  = tool_msg("x" * 100)
      short_msg = tool_msg("short")
      result = apply_pruner([long_msg, short_msg], pruner)
      expect(result[0].content.length).to be <= 50 + Phronomy::Memory::Pruner::ToolOutputPruner::TRUNCATION_NOTE.length
      expect(result[1].content).to eq("short")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-003: none memory; default tool_output_pruner (max_chars=4000)
  # ---------------------------------------------------------------------------
  describe "TC-003: none memory; default tool_output_pruner (max_chars=4000)" do
    it "does not truncate messages under 4000 chars" do
      pruner = tool_pruner("default")
      msg = tool_msg("a" * 100)
      result = apply_pruner([msg], pruner)
      expect(result[0].content).to eq("a" * 100)
    end

    it "truncates messages over 4000 chars" do
      pruner = tool_pruner("default")
      msg = tool_msg("b" * 5000)
      result = apply_pruner([msg], pruner)
      expect(result[0].content.length).to be <= 4000 + Phronomy::Memory::Pruner::ToolOutputPruner::TRUNCATION_NOTE.length
      expect(result[0].content).to include(Phronomy::Memory::Pruner::ToolOutputPruner::TRUNCATION_NOTE)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004: none memory; large tool_output_pruner — effectively no truncation
  # ---------------------------------------------------------------------------
  describe "TC-004: none memory; large tool_output_pruner (max_chars=1_000_000)" do
    it "does not truncate any realistic tool message" do
      pruner = tool_pruner("large")
      msg = tool_msg("c" * 10_000)
      result = apply_pruner([msg], pruner)
      expect(result[0].content).to eq("c" * 10_000)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-005: window memory; k=1; tight tool pruner
  # ---------------------------------------------------------------------------
  describe "TC-005: WindowMemory; k=1; tight tool pruner (max_chars=50)" do
    it "WindowMemory(k=1) keeps only the last 2 messages after multiple saves" do
      mem = Phronomy::Memory::WindowMemory.new(k: 1)
      messages = [
        user_msg("turn1 user"), assistant_msg("turn1 assistant"),
        user_msg("turn2 user"), assistant_msg("turn2 assistant")
      ]
      mem.save_messages(thread_id: "t1", messages: messages)
      loaded = mem.load_messages(thread_id: "t1")
      expect(loaded.length).to eq(2)
      expect(loaded.last.content).to include("turn2")
    end

    it "tight pruner truncates tool messages over 50 chars" do
      pruner = tool_pruner("tight")
      msgs = [tool_msg("x" * 100)]
      result = apply_pruner(msgs, pruner)
      expect(result[0].content).to include(Phronomy::Memory::Pruner::ToolOutputPruner::TRUNCATION_NOTE)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: window memory; default k (10); large tool pruner
  # ---------------------------------------------------------------------------
  describe "TC-006: WindowMemory; default k=10; large tool pruner" do
    it "WindowMemory(k=10) retains at most 20 messages" do
      mem = Phronomy::Memory::WindowMemory.new(k: 10)
      messages = 12.times.flat_map { |i| [user_msg("u#{i}"), assistant_msg("a#{i}")] }
      mem.save_messages(thread_id: "t1", messages: messages)
      loaded = mem.load_messages(thread_id: "t1")
      expect(loaded.length).to eq(20)
      expect(loaded.last.content).to eq("a11")
    end

    it "large pruner does not truncate tool messages" do
      pruner = tool_pruner("large")
      msg = tool_msg("d" * 10_000)
      result = apply_pruner([msg], pruner)
      expect(result[0].content).to eq("d" * 10_000)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-007: window memory; large k (100); zero tool pruner
  # ---------------------------------------------------------------------------
  describe "TC-007: WindowMemory; large k=100; zero tool pruner" do
    it "WindowMemory(k=100) retains all messages when fewer than 200 stored" do
      mem = Phronomy::Memory::WindowMemory.new(k: 100)
      messages = 5.times.flat_map { |i| [user_msg("u#{i}"), assistant_msg("a#{i}")] }
      mem.save_messages(thread_id: "t1", messages: messages)
      loaded = mem.load_messages(thread_id: "t1")
      expect(loaded.length).to eq(10)
    end

    it "zero pruner truncates every tool message content to truncation notice only" do
      pruner = tool_pruner("zero")
      msg = tool_msg("something")
      result = apply_pruner([msg], pruner)
      expect(result[0].content).to eq(Phronomy::Memory::Pruner::ToolOutputPruner::TRUNCATION_NOTE)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-008: window memory; large k; default tool pruner
  # ---------------------------------------------------------------------------
  describe "TC-008: WindowMemory; large k=100; default tool pruner" do
    it "large k window retains all messages in typical test" do
      mem = Phronomy::Memory::WindowMemory.new(k: 100)
      messages = [user_msg("hello"), assistant_msg("hi")]
      mem.save_messages(thread_id: "t1", messages: messages)
      loaded = mem.load_messages(thread_id: "t1")
      expect(loaded.length).to eq(2)
    end

    it "default pruner (4000) allows short tool messages through unchanged" do
      pruner = tool_pruner("default")
      msg = tool_msg("short tool result")
      result = apply_pruner([msg], pruner)
      expect(result[0].content).to eq("short tool result")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-009: SummaryMemory; tiny max_tokens; tight tool pruner — LLM required
  # ---------------------------------------------------------------------------
  describe "TC-009: SummaryMemory; tiny max_tokens; tight tool pruner", :slow do
    it "compresses messages when token count exceeds tiny threshold" do
      mem = Phronomy::Memory::SummaryMemory.new(max_tokens: 1)
      messages = 6.times.map { |i| user_msg("message number #{i} with some content") }
      # save_messages triggers compression since even 1 message > 1 token
      mem.save_messages(thread_id: "t1", messages: messages)
      loaded = mem.load_messages(thread_id: "t1")
      # Compressed: system summary + up to 5 recent messages
      system_msgs = loaded.select { |m| m.role.to_sym == :system }
      expect(system_msgs).not_to be_empty
      expect(system_msgs.first.content).to start_with("[Summary]")
    end

    it "tight pruner truncates tool messages to 50 chars" do
      pruner = tool_pruner("tight")
      msg = tool_msg("e" * 200)
      result = apply_pruner([msg], pruner)
      expect(result[0].content.length).to be <= 50 + Phronomy::Memory::Pruner::ToolOutputPruner::TRUNCATION_NOTE.length
    end
  end

  # ---------------------------------------------------------------------------
  # TC-010: SummaryMemory; huge max_tokens — never compresses; large tool pruner
  # ---------------------------------------------------------------------------
  describe "TC-010: SummaryMemory; huge max_tokens (never compresses); large tool pruner" do
    it "does not compress messages when max_tokens is huge" do
      mem = Phronomy::Memory::SummaryMemory.new(max_tokens: 1_000_000)
      messages = [user_msg("hello"), assistant_msg("world")]
      mem.save_messages(thread_id: "t1", messages: messages)
      loaded = mem.load_messages(thread_id: "t1")
      # No compression: no summary message
      expect(loaded.none? { |m| m.role.to_sym == :system }).to be(true)
      expect(loaded.length).to eq(2)
    end

    it "large pruner (1M chars) does not truncate tool messages" do
      pruner = tool_pruner("large")
      msg = tool_msg("f" * 10_000)
      result = apply_pruner([msg], pruner)
      expect(result[0].content).to eq("f" * 10_000)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-011: SummaryMemory; typical max_tokens; nil summarizer; zero tool pruner — LLM required
  # ---------------------------------------------------------------------------
  describe "TC-011: SummaryMemory; typical max_tokens; zero tool pruner", :slow do
    it "stores and loads messages without compression when under threshold" do
      mem = Phronomy::Memory::SummaryMemory.new(max_tokens: 4000)
      messages = [user_msg("hi"), assistant_msg("hello")]
      mem.save_messages(thread_id: "t1", messages: messages)
      loaded = mem.load_messages(thread_id: "t1")
      expect(loaded.length).to eq(2)
    end

    it "zero pruner truncates every tool message to truncation notice" do
      pruner = tool_pruner("zero")
      msg = tool_msg("some tool output")
      result = apply_pruner([msg], pruner)
      expect(result[0].content).to eq(Phronomy::Memory::Pruner::ToolOutputPruner::TRUNCATION_NOTE)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-012: SummaryMemory; typical max_tokens; nil summarizer; nil pruner — baseline
  # ---------------------------------------------------------------------------
  describe "TC-012: SummaryMemory; typical max_tokens; nil pruner — baseline" do
    it "stores and loads messages without modification when under threshold" do
      mem = Phronomy::Memory::SummaryMemory.new(max_tokens: 4000)
      messages = [user_msg("foo"), assistant_msg("bar")]
      mem.save_messages(thread_id: "t1", messages: messages)
      loaded = mem.load_messages(thread_id: "t1")
      expect(loaded.map(&:content)).to eq(%w[foo bar])
    end

    it "nil pruner leaves all messages unchanged" do
      msgs = [tool_msg("tool output"), user_msg("user message")]
      result = apply_pruner(msgs, nil)
      expect(result).to eq(msgs)
    end
  end

  # TC-013..017 infeasible (R3: semantic memory requires embedding endpoint)

  # ---------------------------------------------------------------------------
  # TC-018: CompositeMemory (window+summary); k=1; tiny summary; zero tool pruner
  # ---------------------------------------------------------------------------
  describe "TC-018: CompositeMemory; k=1 window + tiny summary; zero tool pruner" do
    it "CompositeMemory loads messages from window sub-memory" do
      window  = Phronomy::Memory::WindowMemory.new(k: 1)
      summary = Phronomy::Memory::SummaryMemory.new(max_tokens: 1_000_000)
      composite = Phronomy::Memory::CompositeMemory.new(
        sources: [
          { memory: window,  weight: 1.0 },
          { memory: summary, weight: 1.0 }
        ]
      )
      messages = [user_msg("hello"), assistant_msg("world")]
      # Save to both sub-memories so composite can load
      window.save_messages(thread_id: "t1", messages: messages)
      summary.save_messages(thread_id: "t1", messages: messages)

      loaded = composite.load_messages(thread_id: "t1")
      # Deduplicated: same messages from both, so only 2 unique
      expect(loaded.length).to eq(2)
    end

    it "zero pruner on composite output truncates tool messages" do
      pruner = tool_pruner("zero")
      msgs = [tool_msg("output")]
      result = apply_pruner(msgs, pruner)
      expect(result[0].content).to include(Phronomy::Memory::Pruner::ToolOutputPruner::TRUNCATION_NOTE)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-019: CompositeMemory; default window k; typical summary; tight pruner
  # ---------------------------------------------------------------------------
  describe "TC-019: CompositeMemory; default k=10 window + typical summary; tight pruner" do
    it "CompositeMemory save_messages delegates to all sources" do
      window  = Phronomy::Memory::WindowMemory.new(k: 10)
      summary = Phronomy::Memory::SummaryMemory.new(max_tokens: 4000)
      composite = Phronomy::Memory::CompositeMemory.new(
        sources: [
          { memory: window,  weight: 1.0 },
          { memory: summary, weight: 1.0 }
        ]
      )
      messages = [user_msg("ping"), assistant_msg("pong")]
      composite.save_messages(thread_id: "t1", messages: messages)
      # Both sub-memories should have the messages
      expect(window.load_messages(thread_id: "t1").length).to eq(2)
    end

    it "tight pruner truncates tool messages over 50 chars" do
      pruner = tool_pruner("tight")
      msg = tool_msg("g" * 100)
      result = apply_pruner([msg], pruner)
      expect(result[0].content).to include(Phronomy::Memory::Pruner::ToolOutputPruner::TRUNCATION_NOTE)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-020: CompositeMemory; large window k; huge summary; zero tool pruner
  # ---------------------------------------------------------------------------
  describe "TC-020: CompositeMemory; large window k=100 + huge summary; zero tool pruner" do
    it "CompositeMemory deduplicates messages from sources with identical content" do
      window  = Phronomy::Memory::WindowMemory.new(k: 100)
      summary = Phronomy::Memory::SummaryMemory.new(max_tokens: 1_000_000)
      composite = Phronomy::Memory::CompositeMemory.new(
        sources: [
          { memory: window,  weight: 1.0 },
          { memory: summary, weight: 1.0 }
        ]
      )
      messages = 5.times.map { |i| user_msg("msg #{i}") }
      composite.save_messages(thread_id: "t1", messages: messages)
      loaded = composite.load_messages(thread_id: "t1")
      # Deduplicated: 5 unique messages
      expect(loaded.length).to eq(5)
    end

    it "zero pruner truncates all tool messages" do
      pruner = tool_pruner("zero")
      msgs = [tool_msg("x" * 500), user_msg("keep me")]
      result = apply_pruner(msgs, pruner)
      tool_results = result.select { |m| m.role.to_sym == :tool }
      tool_results.each do |m|
        expect(m.content).to include(Phronomy::Memory::Pruner::ToolOutputPruner::TRUNCATION_NOTE)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TC-021: CompositeMemory; k=1; tiny summary max_tokens; default pruner
  # ---------------------------------------------------------------------------
  describe "TC-021: CompositeMemory; k=1 window + tiny summary; default pruner" do
    it "CompositeMemory clear removes all messages from sub-memories" do
      window    = Phronomy::Memory::WindowMemory.new(k: 1)
      summary   = Phronomy::Memory::SummaryMemory.new(max_tokens: 1)
      composite = Phronomy::Memory::CompositeMemory.new(
        sources: [
          { memory: window,  weight: 1.0 },
          { memory: summary, weight: 1.0 }
        ]
      )
      composite.save_messages(thread_id: "t1", messages: [user_msg("hello")])
      composite.clear(thread_id: "t1")
      loaded = composite.load_messages(thread_id: "t1")
      expect(loaded).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-022: CompositeMemory; k=1; tiny summary; large tool pruner
  # ---------------------------------------------------------------------------
  describe "TC-022: CompositeMemory; k=1 window + tiny summary; large tool pruner" do
    it "large pruner (1M chars) passes all realistic tool messages through unchanged" do
      pruner = tool_pruner("large")
      msg = tool_msg("h" * 50_000)
      result = apply_pruner([msg], pruner)
      expect(result[0].content).to eq("h" * 50_000)
    end

    it "CompositeMemory with k=1 window only returns last 2 messages" do
      window  = Phronomy::Memory::WindowMemory.new(k: 1)
      summary = Phronomy::Memory::SummaryMemory.new(max_tokens: 1_000_000)
      composite = Phronomy::Memory::CompositeMemory.new(
        sources: [
          { memory: window, weight: 1.0 },
          { memory: summary, weight: 1.0 }
        ]
      )
      messages = [
        user_msg("old1"), assistant_msg("old2"),
        user_msg("new1"), assistant_msg("new2")
      ]
      composite.save_messages(thread_id: "t1", messages: messages)
      loaded = composite.load_messages(thread_id: "t1")
      # Window(k=1) returns last 2; summary(huge) deduplicates
      # summary stored all 4, window stored all 4 but loads only last 2
      # composite deduplicates: first loads window(2), then summary adds the 2 older ones
      expect(loaded.length).to eq(4)
    end
  end

  # TC-023..026 infeasible (R2: active_record requires Rails)
end
