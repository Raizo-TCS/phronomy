# frozen_string_literal: true

require "spec_helper"
require_relative "../../../support/active_record_setup"

RSpec.describe Phronomy::Memory::Storage::ActiveRecord do
  # Regression test for Issue #54:
  # ActiveRecord::Storage#save converts nil message content to empty string,
  # causing incorrect ReactAgent output on resume.

  subject(:storage) do
    described_class.new(model_class: PhronomyMessageRecord)
  end

  # A minimal Struct that mimics a RubyLLM::Message with nil content
  # (as produced by tool-call request messages).
  NilContentMessage = Struct.new(:role, :content, :tool_calls, :model_id, keyword_init: true)

  before { PhronomyMessageRecord.delete_all }

  describe "#save / #load round-trip" do
    context "with a message that has nil content (tool-call request, Issue #54)" do
      it "preserves nil content after save/load round-trip (Issue #54)" do
        # A tool-call request from the assistant has content: nil in RubyLLM.
        msg = NilContentMessage.new(role: :assistant, content: nil, tool_calls: nil, model_id: nil)
        storage.save(thread_id: "t1", messages: [msg])
        loaded = storage.load(thread_id: "t1")

        # The content must be nil after round-trip, not an empty string.
        # Without the fix, this returns "" because save does msg.content.to_s.
        expect(loaded.first.content).to be_nil
      end
    end

    context "with a message that has non-nil content" do
      it "preserves non-nil string content" do
        msg = NilContentMessage.new(role: :user, content: "Hello", tool_calls: nil, model_id: nil)
        storage.save(thread_id: "t1", messages: [msg])
        loaded = storage.load(thread_id: "t1")
        expect(loaded.first.content).to eq("Hello")
      end

      it "preserves the role as symbol" do
        msg = NilContentMessage.new(role: :user, content: "Hi", tool_calls: nil, model_id: nil)
        storage.save(thread_id: "t1", messages: [msg])
        loaded = storage.load(thread_id: "t1")
        expect(loaded.first.role).to eq(:user)
      end
    end

    context "with multiple messages in sequence" do
      it "preserves order and all contents" do
        msgs = [
          NilContentMessage.new(role: :user, content: "Question", tool_calls: nil, model_id: nil),
          NilContentMessage.new(role: :assistant, content: nil, tool_calls: nil, model_id: nil),
          NilContentMessage.new(role: :user, content: "Result", tool_calls: nil, model_id: nil),
          NilContentMessage.new(role: :assistant, content: "Answer", tool_calls: nil, model_id: nil)
        ]
        storage.save(thread_id: "t1", messages: msgs)
        loaded = storage.load(thread_id: "t1")

        expect(loaded.length).to eq(4)
        expect(loaded[1].content).to be_nil  # tool-call message, content must remain nil
        expect(loaded[3].content).to eq("Answer")
      end
    end

    it "replaces existing messages on subsequent save" do
      msgs_a = [NilContentMessage.new(role: :user, content: "first", tool_calls: nil, model_id: nil)]
      msgs_b = [NilContentMessage.new(role: :user, content: "second", tool_calls: nil, model_id: nil)]
      storage.save(thread_id: "t1", messages: msgs_a)
      storage.save(thread_id: "t1", messages: msgs_b)
      loaded = storage.load(thread_id: "t1")
      expect(loaded.length).to eq(1)
      expect(loaded.first.content).to eq("second")
    end

    it "isolates messages between different thread_ids" do
      storage.save(thread_id: "t1", messages: [NilContentMessage.new(role: :user, content: "t1msg", tool_calls: nil, model_id: nil)])
      storage.save(thread_id: "t2", messages: [NilContentMessage.new(role: :user, content: "t2msg", tool_calls: nil, model_id: nil)])
      expect(storage.load(thread_id: "t1").first.content).to eq("t1msg")
      expect(storage.load(thread_id: "t2").first.content).to eq("t2msg")
    end
  end

  describe "#clear" do
    it "removes all messages for the given thread_id" do
      msg = NilContentMessage.new(role: :user, content: "hello", tool_calls: nil, model_id: nil)
      storage.save(thread_id: "t1", messages: [msg])
      storage.clear(thread_id: "t1")
      expect(storage.load(thread_id: "t1")).to be_empty
    end

    it "does not affect messages for other threads" do
      storage.save(thread_id: "t1", messages: [NilContentMessage.new(role: :user, content: "t1", tool_calls: nil, model_id: nil)])
      storage.save(thread_id: "t2", messages: [NilContentMessage.new(role: :user, content: "t2", tool_calls: nil, model_id: nil)])
      storage.clear(thread_id: "t1")
      expect(storage.load(thread_id: "t2").first.content).to eq("t2")
    end
  end
end

# Regression test for Issue #59:
# ActiveRecord::Storage#append_raw must wrap multiple create! calls in a
# transaction so that a mid-batch failure does not leave partial records.
RSpec.describe Phronomy::Memory::Storage::ActiveRecord, "Issue #59 – append_raw atomicity" do
  subject(:storage) do
    described_class.new(
      model_class: PhronomyMessageRecord,
      raw_model_class: PhronomyRawMessageRecord
    )
  end

  AppendRawMsg = Struct.new(:role, :content, :tool_calls, :model_id, keyword_init: true)

  before do
    PhronomyMessageRecord.delete_all
    PhronomyRawMessageRecord.delete_all
  end

  it "rolls back all raw records when a mid-batch create! fails (Issue #59)" do
    msgs = [
      AppendRawMsg.new(role: :user, content: "msg0", tool_calls: nil, model_id: nil),
      AppendRawMsg.new(role: :assistant, content: "msg1", tool_calls: nil, model_id: nil),
      AppendRawMsg.new(role: :user, content: "msg2", tool_calls: nil, model_id: nil)
    ]

    # Intercept the second create! and raise to simulate a mid-batch DB error.
    call_count = 0
    allow(PhronomyRawMessageRecord).to receive(:create!).and_wrap_original do |orig, **args|
      call_count += 1
      raise ActiveRecord::RecordInvalid.new(PhronomyRawMessageRecord.new) if call_count == 2
      orig.call(**args)
    end

    expect {
      storage.append_raw(thread_id: "t1", messages: msgs, starting_seq: 0)
    }.to raise_error(ActiveRecord::RecordInvalid)

    # Without a transaction, msg0 (call 1) would already be committed.
    # With a proper transaction, the count must be 0.
    expect(PhronomyRawMessageRecord.where(thread_id: "t1").count).to eq(0)
  end
end
