# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::ExecutionMetadata do
  describe ".build_tool_batch_snapshot" do
    def make_tool_inv(id:, tool_call_id:, completed:, result: nil)
      inv = double("tool_inv_#{id}",
        id: id,
        tool_call_id: tool_call_id,
        tool_name: "tool_#{id}",
        raw_arguments: {"x" => 1},
        status: completed ? :completed : :pending,
        execution_completed?: completed)
      allow(inv).to receive(:result).and_return(result) if completed
      inv
    end

    it "excludes result key when execution is not completed" do
      inv = make_tool_inv(id: "inv-1", tool_call_id: "call-1", completed: false)
      invocation = double("invocation", tool_invocations: [inv], tool_batch_llm_call_id: "llm-1")
      result = described_class.build_tool_batch_snapshot(invocation)
      expect(result.first).not_to have_key("result")
    end

    it "includes result key when execution is completed" do
      inv = make_tool_inv(id: "inv-2", tool_call_id: "call-2", completed: true, result: "ok")
      invocation = double("invocation", tool_invocations: [inv], tool_batch_llm_call_id: "llm-2")
      result = described_class.build_tool_batch_snapshot(invocation)
      expect(result.first["result"]).to eq("ok")
    end

    it "omits tool_call_id key when nil" do
      inv = make_tool_inv(id: "inv-3", tool_call_id: nil, completed: false)
      invocation = double("invocation", tool_invocations: [inv], tool_batch_llm_call_id: nil)
      result = described_class.build_tool_batch_snapshot(invocation)
      expect(result.first).not_to have_key("tool_call_id")
      expect(result.first).not_to have_key("llm_call_id")
    end
  end
end
