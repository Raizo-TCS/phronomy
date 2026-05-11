# frozen_string_literal: true

require "spec_helper"
require "ostruct"

RSpec.describe Phronomy::Memory::Compression::Summary do
  def make_msg(role, content)
    OpenStruct.new(role: role, content: content)
  end

  # Approximate token count: TokenEstimator.estimate uses content.split.size.
  # Each word ~ 1 token. 4000 tokens = ~4000 words.
  def large_messages(n, words_each: 10)
    n.times.map { |i| make_msg(:user, "word " * words_each + "msg#{i}") }
  end

  subject(:compressor) { described_class.new(max_tokens: 100, keep: 2) }

  describe "#compress" do
    context "when total tokens are within threshold" do
      it "returns messages unchanged and compaction: nil" do
        msgs = [make_msg(:user, "hello"), make_msg(:assistant, "hi")]
        result = compressor.compress(thread_id: "t1", messages: msgs)
        expect(result[:messages]).to eq(msgs)
        expect(result[:compaction]).to be_nil
      end
    end

    context "when total tokens exceed threshold and message count > keep" do
      let(:chat_double) { instance_double("RubyLLM::Chat") }

      before do
        allow(RubyLLM).to receive(:chat).and_return(chat_double)
        allow(chat_double).to receive(:ask).and_return(
          OpenStruct.new(content: "This is a summary.")
        )
      end

      let(:msgs) do
        # 10 messages × ~15 tokens each ≈ 150 tokens (> 100 threshold)
        10.times.map { |i| make_msg(:user, ("word " * 15).strip + " #{i}") }
      end

      it "calls the LLM to generate a summary" do
        compressor.compress(thread_id: "t1", messages: msgs)
        expect(chat_double).to have_received(:ask).once
      end

      it "keeps only the last :keep messages verbatim" do
        result = compressor.compress(thread_id: "t1", messages: msgs)
        expect(result[:messages].last(2)).to eq(msgs.last(2))
      end

      it "prepends a summary system message" do
        result = compressor.compress(thread_id: "t1", messages: msgs)
        expect(result[:messages].first.role).to eq(:system)
        expect(result[:messages].first.content).to include("This is a summary.")
      end

      it "returns a compaction hash with start_seq, end_seq, summary_text" do
        result = compressor.compress(thread_id: "t1", messages: msgs, seq_offset: 5)
        expect(result[:compaction]).to include(
          start_seq: 5,
          end_seq: 5 + (msgs.length - 2) - 1,
          summary_text: "This is a summary."
        )
      end
    end

    # Regression test for Issue #58:
    # When the LLM call inside compact raises, compress must NOT propagate the
    # exception — it must fall back to returning the original messages unchanged.
    context "when the LLM call raises (Issue #58)" do
      let(:chat_double) { instance_double("RubyLLM::Chat") }

      before do
        allow(RubyLLM).to receive(:chat).and_return(chat_double)
        allow(chat_double).to receive(:ask).and_raise(StandardError, "LLM API timeout")
      end

      let(:msgs) do
        10.times.map { |i| make_msg(:user, ("word " * 15).strip + " #{i}") }
      end

      it "does NOT propagate the LLM error (Issue #58)" do
        expect {
          compressor.compress(thread_id: "t1", messages: msgs)
        }.not_to raise_error
      end

      it "falls back to returning original messages with compaction: nil (Issue #58)" do
        result = compressor.compress(thread_id: "t1", messages: msgs)
        expect(result[:messages]).to eq(msgs)
        expect(result[:compaction]).to be_nil
      end
    end
  end
end
