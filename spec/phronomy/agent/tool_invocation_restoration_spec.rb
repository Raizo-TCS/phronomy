# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::ToolInvocation, "saved state restoration" do
  let(:tool_class) do
    Class.new(Phronomy::Tool::Base) do
      tool_name "restored_operation"
      description "Restoration boundary fixture"
      param :count, type: :integer, desc: "Count"
      requires_approval true

      def execute(count:)
        raise "Restoration must not execute the Tool"
      end
    end
  end
  let(:tool) { tool_class.new }
  let(:tool_call) do
    Struct.new(:id, :name, :arguments).new("call-1", "restored_operation", {"count" => 3})
  end
  let(:invocation) do
    described_class.new(execution_id: "execution-1", agent: Object.new,
      tool: tool, tool_call: tool_call, config: {}, id: "invocation-1")
  end

  def restore(child, status:, result: nil, approval_item: nil)
    child.restore_state!(status: status, result: result, approval_item: approval_item)
  end

  def approval_item(facts: {"count" => 3, "labels" => ["saved"]})
    Phronomy::Agent::ToolApprovalRequest::Item.new(
      tool_invocation_id: "invocation-1", tool_call_id: "call-1",
      tool_name: "restored_operation", arguments: {"count" => 3},
      facts: facts, reason: "saved approval reason", origin: :local, metadata: {}
    )
  end

  [:awaiting_approval, :authorized].each do |status|
    it "restores #{status} with validated arguments and no dispatch or approval evaluation" do
      expect(tool).not_to receive(:call)
      expect(tool).not_to receive(:call_async)
      expect(tool).not_to receive(:execute)
      expect(invocation).not_to receive(:start_authorization)
      expect(invocation).not_to receive(:start_execution)
      expect(Phronomy::Runtime).not_to receive(:instance)

      expect(restore(invocation, status: status)).to be(invocation)
      expect(invocation.status).to eq(status)
      expect(invocation.arguments).to eq(count: 3)
      expect(invocation.arguments).to be_frozen
      expect(invocation.final_decision).to eq((status == :authorized) ? :allow : :require_approval)
      expect(invocation).to be_preflight_settled
      expect(invocation).not_to be_terminal
      expect(invocation).not_to be_dispatchable
      expect([invocation.execution_id, invocation.id, invocation.tool_call_id])
        .to eq(["execution-1", "invocation-1", "call-1"])
    end
  end

  it "requires an approval decision before a restored waiting invocation becomes dispatchable" do
    restore(invocation, status: :awaiting_approval)
    invocation.mark_queued!
    expect(invocation).not_to be_dispatchable
  end

  it "preserves approval consumption when a restored wait is authorized and queued" do
    restore(invocation, status: :awaiting_approval)
    invocation.mark_authorized!
    invocation.mark_queued!
    expect(invocation).to be_dispatchable
    expect(invocation.final_decision).to eq(:require_approval)
  end

  it "allows a saved authorization to dispatch only after queuing" do
    restore(invocation, status: :authorized)
    invocation.mark_queued!
    expect(invocation).to be_dispatchable
  end

  [:completed, :rejected, :failed, :cancelled].each do |status|
    it "restores terminal #{status} without validating or executing the Tool" do
      expect(tool).not_to receive(:validate_and_coerce)
      expect(tool).not_to receive(:execute)
      restore(invocation, status: status, result: "saved output")
      expect(invocation.status).to eq(status)
      expect(invocation).to be_terminal
      expect(invocation).to be_preflight_settled
      expect(invocation).not_to be_dispatchable
      expect(invocation.arguments).to be_nil
      expect(invocation.result).to eq((status == :completed) ? "saved output" : nil)
      expect(invocation.final_decision).to eq((status == :rejected) ? :reject : nil)
      if status == :failed
        expect(invocation.error).to be_a(Phronomy::ToolError)
        expect(invocation.error.message).to eq("durably restored Tool preflight failure")
      else
        expect(invocation.error).to be_nil
      end
    end
  end

  [nil, false, {"saved" => [1, "value"]}].each do |result|
    it "preserves the completed result #{result.inspect}" do
      restore(invocation, status: :completed, result: result)
      expect(invocation).to be_execution_completed
      expect(invocation.result).to equal(result)
    end
  end

  it "restores saved completion even when the Tool definition is no longer available" do
    child = described_class.missing(execution_id: "execution-1", agent: Object.new,
      tool_call: tool_call, config: {}, id: "invocation-1")
    restore(child, status: :completed, result: "previous output")
    expect(child.result).to eq("previous output")
    expect(child).to be_execution_completed
  end

  it "copies saved approval evidence without evaluating current approval rules" do
    item = approval_item
    expect(tool_class).not_to receive(:approval_facts)
    expect(tool_class).not_to receive(:requires_approval)
    restore(invocation, status: :awaiting_approval, approval_item: item)
    expect(invocation.facts).to eq(item.facts)
    expect(invocation.facts).not_to equal(item.facts)
    expect(invocation.facts.fetch("labels")).to be_frozen
    expect(invocation.authorization_reason).to eq("saved approval reason")
    expect(invocation.approval_context).to eq({})
  end

  it "preserves absent approval evidence as the constructor defaults" do
    restore(invocation, status: :authorized)
    expect(invocation.facts).to eq({})
    expect(invocation.facts).to be_frozen
    expect(invocation.authorization_reason).to be_nil
  end

  it "preserves an explicitly nil saved facts value and its reason" do
    restore(invocation, status: :rejected, approval_item: approval_item(facts: nil))
    expect(invocation.facts).to be_nil
    expect(invocation.authorization_reason).to eq("saved approval reason")
  end

  [:created, :queued, :running, :unsupported].each do |status|
    it "rejects unsupported saved #{status} before changing state or approval evidence" do
      expect {
        restore(invocation, status: status, approval_item: approval_item)
      }.to raise_error(Phronomy::ExecutionRehydrationRequiredError,
        "unsupported durable Tool snapshot state: #{status.inspect}")
      expect(invocation.status).to eq(:created)
      expect(invocation.arguments).to be_nil
      expect(invocation.facts).to eq({})
      expect(invocation.authorization_reason).to be_nil
    end
  end
end
