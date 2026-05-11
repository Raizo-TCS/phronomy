# frozen_string_literal: true

require "spec_helper"
require "ostruct"

RSpec.describe Phronomy::Memory::Compression::ToolOutputPruner do
  def make_msg(role, content)
    OpenStruct.new(role: role, content: content)
  end

  subject(:compressor) { described_class.new(max_chars: 20) }

  describe "#compress" do
    it "leaves short tool messages unchanged" do
      msg = make_msg(:tool, "short output")
      result = compressor.compress(thread_id: "t1", messages: [msg])
      expect(result[:messages].first.content).to eq("short output")
    end

    it "truncates oversized tool messages" do
      msg = make_msg(:tool, "x" * 100)
      result = compressor.compress(thread_id: "t1", messages: [msg])
      expect(result[:messages].first.content.length).to be <= 20 + described_class::TRUNCATION_NOTE.length
      expect(result[:messages].first.content).to end_with(described_class::TRUNCATION_NOTE)
    end

    it "does not modify non-tool messages" do
      user_msg = make_msg(:user, "x" * 100)
      result = compressor.compress(thread_id: "t1", messages: [user_msg])
      expect(result[:messages].first.content).to eq("x" * 100)
    end

    it "handles mixed message arrays" do
      user_msg = make_msg(:user, "hello")
      tool_msg = make_msg(:tool, "y" * 50)
      asst_msg = make_msg(:assistant, "response")
      result = compressor.compress(thread_id: "t1", messages: [user_msg, tool_msg, asst_msg])
      expect(result[:messages][0].content).to eq("hello")
      expect(result[:messages][1].content).to include(described_class::TRUNCATION_NOTE)
      expect(result[:messages][2].content).to eq("response")
    end

    it "is stateless: thread_id has no effect" do
      msg = make_msg(:tool, "x" * 100)
      r1 = compressor.compress(thread_id: "t1", messages: [msg])
      r2 = compressor.compress(thread_id: "t2", messages: [msg])
      expect(r1[:messages].first.content).to eq(r2[:messages].first.content)
    end

    it "always returns compaction: nil" do
      msg = make_msg(:tool, "x" * 100)
      result = compressor.compress(thread_id: "t1", messages: [msg])
      expect(result[:compaction]).to be_nil
    end
  end

  # Regression test for Issue #53: cloned message objects must not use OpenStruct,
  # which silently returns nil for any unknown method call (including typos).
  describe "cloned message value object (Issue #53)" do
    it "raises NoMethodError for unknown attributes (not silently nil)" do
      msg = make_msg(:tool, "x" * 100)
      result = compressor.compress(thread_id: "t1", messages: [msg])
      cloned = result[:messages].first
      expect { cloned.nonexistent_attribute }.to raise_error(NoMethodError)
    end

    it "preserves role and content on cloned messages" do
      msg = make_msg(:tool, "x" * 100)
      result = compressor.compress(thread_id: "t1", messages: [msg])
      cloned = result[:messages].first
      expect(cloned.role).to eq(:tool)
      expect(cloned.content).to end_with(described_class::TRUNCATION_NOTE)
    end
  end
end
