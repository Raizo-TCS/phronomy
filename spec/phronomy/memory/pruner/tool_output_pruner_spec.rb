# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Memory::Pruner::ToolOutputPruner do
  subject(:pruner) { described_class.new(max_chars: 20) }

  def make_msg(role, content)
    OpenStruct.new(role: role, content: content)
  end

  describe "#prune" do
    it "leaves non-tool messages unchanged" do
      msgs = [make_msg(:user, "x" * 100), make_msg(:assistant, "y" * 100)]
      result = pruner.prune(msgs)
      expect(result[0].content).to eq("x" * 100)
      expect(result[1].content).to eq("y" * 100)
    end

    it "truncates tool messages that exceed max_chars" do
      msg = make_msg(:tool, "a" * 50)
      result = pruner.prune([msg])
      expect(result.first.content).to start_with("a" * 20)
      expect(result.first.content).to include(Phronomy::Memory::Pruner::ToolOutputPruner::TRUNCATION_NOTE)
    end

    it "preserves tool messages within max_chars" do
      msg = make_msg(:tool, "short")
      result = pruner.prune([msg])
      expect(result.first.content).to eq("short")
    end

    it "preserves the role of truncated messages" do
      msg = make_msg(:tool, "a" * 50)
      result = pruner.prune([msg])
      expect(result.first.role).to eq(:tool)
    end

    it "returns a new message object (does not mutate original)" do
      msg = make_msg(:tool, "a" * 50)
      result = pruner.prune([msg])
      expect(result.first).not_to equal(msg)
      expect(msg.content).to eq("a" * 50)  # original unchanged
    end

    it "returns an empty array for empty input" do
      expect(pruner.prune([])).to eq([])
    end
  end
end
