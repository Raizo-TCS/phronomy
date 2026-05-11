# frozen_string_literal: true

require "spec_helper"

# Regression spec for the ConversationManager shared-state design problem.
#
# CURRENT STATE (failing): ConversationManager stores per-thread-id state in
# two internal Hashes that are shared across all callers:
#   @thread_mutexes  — a Hash of Mutex objects, one per thread_id
#   @raw_seq_hwm     — a Hash of sequence high-water-marks, one per thread_id
#
# These Hashes grow unboundedly and require their own Mutexes (@thread_mutexes_mutex,
# @raw_seq_hwm_mutex) to be safe under concurrent access from multiple callers.
#
# DESIRED STATE (target design): ConversationManager should be stateless with
# respect to per-thread-id data. It should derive the sequence high-water-mark
# directly from Storage on every call (Storage already persists raw messages with
# seq numbers), and should not maintain a long-lived Mutex cache internally.
# This eliminates the need for @thread_mutexes, @raw_seq_hwm, and their guard
# Mutexes entirely.
#
# These specs document the target design and FAIL against the current implementation.

RSpec.describe Phronomy::Memory::ConversationManager, "#shared internal state" do
  def make_msg(content)
    double("Message", role: :user, content: content, tool_calls: nil)
  end

  let(:storage) { Phronomy::Memory::Storage::InMemory.new }
  let(:retrieval) { Phronomy::Memory::Retrieval::Recent.new(k: 10) }
  subject(:manager) { described_class.new(storage: storage, retrieval: retrieval) }

  # ── Target design: no long-lived per-thread-id internal Hashes ──────────────

  it "does not maintain a long-lived per-thread-id Mutex cache (@thread_mutexes)" do
    manager.save(thread_id: "t1", messages: [make_msg("hello")])
    manager.save(thread_id: "t2", messages: [make_msg("world")])

    # After redesign: @thread_mutexes should not exist on the instance.
    expect(manager.instance_variable_defined?(:@thread_mutexes)).to be false
  end

  it "does not maintain a long-lived sequence high-water-mark cache (@raw_seq_hwm)" do
    manager.save(thread_id: "t1", messages: [make_msg("hello")])

    # After redesign: @raw_seq_hwm should not exist on the instance.
    expect(manager.instance_variable_defined?(:@raw_seq_hwm)).to be false
  end

  it "does not require a @thread_mutexes_mutex guard" do
    expect(manager.instance_variable_defined?(:@thread_mutexes_mutex)).to be false
  end

  it "does not require a @raw_seq_hwm_mutex guard" do
    expect(manager.instance_variable_defined?(:@raw_seq_hwm_mutex)).to be false
  end

  # ── Correct seq behaviour must be preserved after redesign ──────────────────

  it "appends messages with monotonically increasing seq numbers across saves" do
    msgs_a = [make_msg("a1"), make_msg("a2")]
    msgs_b = msgs_a + [make_msg("a3"), make_msg("a4")]

    manager.save(thread_id: "t1", messages: msgs_a)
    manager.save(thread_id: "t1", messages: msgs_b)

    raw = storage.load_raw(thread_id: "t1")
    expect(raw.map { |r| r[:seq] }).to eq [0, 1, 2, 3]
  end

  it "derives next seq correctly after TTL purge clears raw store" do
    # Simulate what TTL purge does: empties the raw store for a thread.
    msgs = [make_msg("m1"), make_msg("m2"), make_msg("m3")]
    manager.save(thread_id: "t1", messages: msgs)

    # Force-remove all raw entries using the actual TTL code path.
    # purge_older_than removes records by timestamp but preserves the HWM,
    # matching what ConversationManager#load calls in production.
    storage.purge_older_than(thread_id: "t1", older_than: Time.now + 3600)

    # In real usage the agent's in-memory buffer still contains the full history
    # (TTL purge only clears Storage, not the caller's buffer).  Pass the
    # original messages plus a new one, which is how ConversationManager is
    # always called in production.
    manager.save(thread_id: "t1", messages: msgs + [make_msg("after_purge")])
    raw = storage.load_raw(thread_id: "t1")
    # Seq must be >= 3 (not restarted from 0)
    expect(raw.first[:seq]).to be >= 3
  end

  # ── Unbounded growth must not occur ─────────────────────────────────────────

  it "does not accumulate internal state for thread_ids that are never reused" do
    100.times { |i| manager.save(thread_id: "thread_#{i}", messages: [make_msg("x")]) }

    # After redesign: no internal Hash grows with the number of thread_ids.
    expect(manager.instance_variable_defined?(:@thread_mutexes)).to be false
    expect(manager.instance_variable_defined?(:@raw_seq_hwm)).to be false
  end
end
