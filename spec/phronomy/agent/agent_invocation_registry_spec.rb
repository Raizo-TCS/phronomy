# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::AgentInvocationRegistry do
  let(:request) do
    item = Phronomy::Agent::ToolApprovalRequest::Item.new(
      tool_invocation_id: "tool-1",
      tool_call_id: "call-1",
      tool_name: "write_file",
      arguments: {path: "/tmp/example"},
      facts: {},
      reason: nil,
      origin: :local,
      metadata: {}
    )
    Phronomy::Agent::ToolApprovalRequest.new(
      id: "approval-1",
      agent_invocation_id: "agent-1",
      items: [item]
    )
  end

  let(:invocation) { instance_double(Phronomy::Agent::AgentInvocation, id: "agent-1") }

  before { described_class.clear! }
  after { described_class.clear! }

  it "atomically consumes an approval request only once" do
    described_class.store_suspended(invocation, request)

    first = described_class.consume_approval("agent-1", "approval-1")
    second = described_class.consume_approval("agent-1", "approval-1")

    expect(first.invocation).to equal(invocation)
    expect(second).to be_nil
  end

  it "does not consume a request using a mismatched AgentInvocation ID" do
    described_class.store_suspended(invocation, request)

    expect(
      described_class.consume_approval("other-agent", "approval-1")
    ).to be_nil
    expect(described_class.exists?("agent-1")).to be(true)
  end
end
