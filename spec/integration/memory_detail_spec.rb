# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/llm_stub"

# Group 5: Memory Detail Parameters
# Pairwise factors: memory_type × window_memory_k ×
#                   retrieval_composite × tool_output_pruner_max_chars
# Note: SummaryMemory (TC-009..012) removed — replaced by Compression::Summary
#       via ConversationManager. TC-018..022 now test ConversationManager +
#       Retrieval::Composite (shared-storage multi-strategy retrieval).
# Feasible cases: 13
#   Infeasible (R2): TC-023..026 — active_record requires Rails/ActiveRecord
#   Infeasible (R3): TC-013..017 — semantic requires embedding endpoint

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
    when "nil" then nil
    when "zero" then Phronomy::Memory::Compression::ToolOutputPruner.new(max_chars: 0)
    when "tight" then Phronomy::Memory::Compression::ToolOutputPruner.new(max_chars: 50)
    when "default" then Phronomy::Memory::Compression::ToolOutputPruner.new(max_chars: 4000)
    when "large" then Phronomy::Memory::Compression::ToolOutputPruner.new(max_chars: 1_000_000)
    when "default_max_chars" then Phronomy::Memory::Compression::ToolOutputPruner.new(max_chars: 4000)
    when "tight_max_chars" then Phronomy::Memory::Compression::ToolOutputPruner.new(max_chars: 10)
    else raise ArgumentError, "Unknown pruner label: #{label}"
    end
  end

  # Prune messages (noop if pruner is nil).
  def apply_pruner(messages, pruner)
    pruner ? pruner.compress(thread_id: "test", messages: messages)[:messages] : messages
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
        expect(m.content).to include(Phronomy::Memory::Compression::ToolOutputPruner::TRUNCATION_NOTE)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: none memory; tight tool_output_pruner
  # ---------------------------------------------------------------------------
  describe "TC-002: none memory; tight tool_output_pruner (max_chars=50)" do
    it "truncates tool messages longer than 50 chars and leaves shorter ones intact" do
      pruner = tool_pruner("tight")
      long_msg = tool_msg("x" * 100)
      short_msg = tool_msg("short")
      result = apply_pruner([long_msg, short_msg], pruner)
      expect(result[0].content.length).to be <= 50 + Phronomy::Memory::Compression::ToolOutputPruner::TRUNCATION_NOTE.length
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
      expect(result[0].content.length).to be <= 4000 + Phronomy::Memory::Compression::ToolOutputPruner::TRUNCATION_NOTE.length
      expect(result[0].content).to include(Phronomy::Memory::Compression::ToolOutputPruner::TRUNCATION_NOTE)
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
  # TC-005: ConversationManager with Recent(k=1); tight tool pruner
  # ---------------------------------------------------------------------------
  describe "TC-005: ConversationManager Recent(k=1); tight tool pruner (max_chars=50)" do
    it "Recent(k=1) keeps only the last 2 messages after multiple saves" do
      mem = Phronomy::Memory::ConversationManager.new(
        storage: Phronomy::Memory::Storage::InMemory.new,
        retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 1)
      )
      messages = [
        user_msg("turn1 user"), assistant_msg("turn1 assistant"),
        user_msg("turn2 user"), assistant_msg("turn2 assistant")
      ]
      mem.save(thread_id: "t1", messages: messages)
      loaded = mem.load(thread_id: "t1")
      expect(loaded.length).to eq(2)
      expect(loaded.last.content).to include("turn2")
    end

    it "tight pruner truncates tool messages over 50 chars" do
      pruner = tool_pruner("tight")
      msgs = [tool_msg("x" * 100)]
      result = apply_pruner(msgs, pruner)
      expect(result[0].content).to include(Phronomy::Memory::Compression::ToolOutputPruner::TRUNCATION_NOTE)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: ConversationManager with Recent(k=10); large tool pruner
  # ---------------------------------------------------------------------------
  describe "TC-006: ConversationManager Recent(k=10); large tool pruner" do
    it "Recent(k=10) retains at most 20 messages" do
      mem = Phronomy::Memory::ConversationManager.new(
        storage: Phronomy::Memory::Storage::InMemory.new,
        retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 10)
      )
      messages = 12.times.flat_map { |i| [user_msg("u#{i}"), assistant_msg("a#{i}")] }
      mem.save(thread_id: "t1", messages: messages)
      loaded = mem.load(thread_id: "t1")
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
  # TC-007: ConversationManager with Recent(k=100); zero tool pruner
  # ---------------------------------------------------------------------------
  describe "TC-007: ConversationManager Recent(k=100); zero tool pruner" do
    it "Recent(k=100) retains all messages when fewer than 200 stored" do
      mem = Phronomy::Memory::ConversationManager.new(
        storage: Phronomy::Memory::Storage::InMemory.new,
        retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 100)
      )
      messages = 5.times.flat_map { |i| [user_msg("u#{i}"), assistant_msg("a#{i}")] }
      mem.save(thread_id: "t1", messages: messages)
      loaded = mem.load(thread_id: "t1")
      expect(loaded.length).to eq(10)
    end

    it "zero pruner truncates every tool message content to truncation notice only" do
      pruner = tool_pruner("zero")
      msg = tool_msg("something")
      result = apply_pruner([msg], pruner)
      expect(result[0].content).to eq(Phronomy::Memory::Compression::ToolOutputPruner::TRUNCATION_NOTE)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-008: ConversationManager with Recent(k=100); default tool pruner
  # ---------------------------------------------------------------------------
  describe "TC-008: ConversationManager Recent(k=100); default tool pruner" do
    it "large k retrieval retains all messages in typical test" do
      mem = Phronomy::Memory::ConversationManager.new(
        storage: Phronomy::Memory::Storage::InMemory.new,
        retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 100)
      )
      messages = [user_msg("hello"), assistant_msg("hi")]
      mem.save(thread_id: "t1", messages: messages)
      loaded = mem.load(thread_id: "t1")
      expect(loaded.length).to eq(2)
    end

    it "default pruner (4000) allows short tool messages through unchanged" do
      pruner = tool_pruner("default")
      msg = tool_msg("short tool result")
      result = apply_pruner([msg], pruner)
      expect(result[0].content).to eq("short tool result")
    end
  end

  # TC-009..012 removed — SummaryMemory replaced by Compression::Summary + ConversationManager.
  # TC-013..017 infeasible (R3: semantic memory requires embedding endpoint)

  # ---------------------------------------------------------------------------
  # TC-018: Retrieval::Composite; k=1 + k=50 sources; zero tool pruner
  # ---------------------------------------------------------------------------
  describe "TC-018: Retrieval::Composite; Recent(k=1) + Recent(k=50); zero tool pruner" do
    it "Composite retrieval loads messages from both strategies (deduped)" do
      mem = Phronomy::Memory::ConversationManager.new(
        storage: Phronomy::Memory::Storage::InMemory.new,
        retrieval: Phronomy::Memory::Retrieval::Composite.new(sources: [
          {retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 1), weight: 1.0},
          {retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 50), weight: 1.0}
        ])
      )
      messages = [user_msg("hello"), assistant_msg("world")]
      mem.save(thread_id: "t1", messages: messages)
      loaded = mem.load(thread_id: "t1")
      # Both strategies return the same 2 messages; deduped → 2
      expect(loaded.length).to eq(2)
    end

    it "zero pruner on composite output truncates tool messages" do
      pruner = tool_pruner("zero")
      msgs = [tool_msg("output")]
      result = apply_pruner(msgs, pruner)
      expect(result[0].content).to include(Phronomy::Memory::Compression::ToolOutputPruner::TRUNCATION_NOTE)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-019: Retrieval::Composite; default k=10 + k=50; tight pruner
  # ---------------------------------------------------------------------------
  describe "TC-019: Retrieval::Composite; Recent(k=10) + Recent(k=50); tight pruner" do
    it "ConversationManager save stores to shared storage; load applies composite retrieval" do
      mem = Phronomy::Memory::ConversationManager.new(
        storage: Phronomy::Memory::Storage::InMemory.new,
        retrieval: Phronomy::Memory::Retrieval::Composite.new(sources: [
          {retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 10), weight: 1.0},
          {retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 50), weight: 1.0}
        ])
      )
      messages = [user_msg("ping"), assistant_msg("pong")]
      mem.save(thread_id: "t1", messages: messages)
      loaded = mem.load(thread_id: "t1")
      expect(loaded.length).to eq(2)
    end

    it "tight pruner truncates tool messages over 50 chars" do
      pruner = tool_pruner("tight")
      msg = tool_msg("g" * 100)
      result = apply_pruner([msg], pruner)
      expect(result[0].content).to include(Phronomy::Memory::Compression::ToolOutputPruner::TRUNCATION_NOTE)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-020: Retrieval::Composite; large k; deduplication of overlapping results
  # ---------------------------------------------------------------------------
  describe "TC-020: Retrieval::Composite; large k=100 sources; zero tool pruner" do
    it "Composite deduplicates messages returned by multiple strategies" do
      mem = Phronomy::Memory::ConversationManager.new(
        storage: Phronomy::Memory::Storage::InMemory.new,
        retrieval: Phronomy::Memory::Retrieval::Composite.new(sources: [
          {retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 1), weight: 1.0},
          {retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 100), weight: 1.0}
        ])
      )
      messages = 3.times.map { |i| user_msg("msg #{i}") }
      mem.save(thread_id: "t1", messages: messages)
      loaded = mem.load(thread_id: "t1")
      # Recent(k=1) → last 2; Recent(k=100) → all 3; Composite union deduped → 3
      expect(loaded.length).to eq(3)
    end

    it "zero pruner truncates all tool messages" do
      pruner = tool_pruner("zero")
      msgs = [tool_msg("x" * 500), user_msg("keep me")]
      result = apply_pruner(msgs, pruner)
      tool_results = result.select { |m| m.role.to_sym == :tool }
      tool_results.each do |m|
        expect(m.content).to include(Phronomy::Memory::Compression::ToolOutputPruner::TRUNCATION_NOTE)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TC-021: Retrieval::Composite; clear removes all from shared storage
  # ---------------------------------------------------------------------------
  describe "TC-021: Retrieval::Composite; clear removes shared storage" do
    it "clear removes all messages from the shared storage" do
      mem = Phronomy::Memory::ConversationManager.new(
        storage: Phronomy::Memory::Storage::InMemory.new,
        retrieval: Phronomy::Memory::Retrieval::Composite.new(sources: [
          {retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 1), weight: 1.0},
          {retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 1), weight: 1.0}
        ])
      )
      mem.save(thread_id: "t1", messages: [user_msg("hello")])
      mem.clear(thread_id: "t1")
      loaded = mem.load(thread_id: "t1")
      expect(loaded).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-022: Retrieval::Composite; Recent(k=1) + Recent(k=50); returns union
  # ---------------------------------------------------------------------------
  describe "TC-022: Retrieval::Composite; Recent(k=1) + Recent(k=50); large tool pruner" do
    it "large pruner (1M chars) passes all realistic tool messages through unchanged" do
      pruner = tool_pruner("large")
      msg = tool_msg("h" * 50_000)
      result = apply_pruner([msg], pruner)
      expect(result[0].content).to eq("h" * 50_000)
    end

    it "Composite with Recent(k=1) and Recent(k=50) returns union of results" do
      mem = Phronomy::Memory::ConversationManager.new(
        storage: Phronomy::Memory::Storage::InMemory.new,
        retrieval: Phronomy::Memory::Retrieval::Composite.new(sources: [
          {retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 1), weight: 1.0},
          {retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 50), weight: 1.0}
        ])
      )
      messages = [
        user_msg("old1"), assistant_msg("old2"),
        user_msg("new1"), assistant_msg("new2")
      ]
      mem.save(thread_id: "t1", messages: messages)
      loaded = mem.load(thread_id: "t1")
      # Recent(k=1) → last 2 (new1, new2); Recent(k=50) → all 4
      # Composite: new1/new2 first (from k=1), then old1/old2 added (from k=50)
      # union deduped → 4
      expect(loaded.length).to eq(4)
    end
  end

  # TC-023..026 infeasible (R2: active_record requires Rails)
end
