# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::AgentInvocation do
  FakeChild = Struct.new(:id, :status, :error) do
    def awaiting_approval?
      status == :awaiting_approval
    end

    def authorized?
      status == :authorized
    end

    def rejected?
      status == :rejected
    end

    def failed?
      status == :failed
    end

    def cancelled?
      status == :cancelled
    end

    def execution_completed?
      status == :completed
    end

    def terminal?
      %i[completed rejected failed cancelled].include?(status)
    end

    def preflight_settled?
      %i[authorized awaiting_approval completed rejected failed cancelled].include?(status)
    end
  end

  let(:agent) { instance_double(Phronomy::Agent::Base) }
  let(:invocation) do
    described_class.new(agent: agent, input: "hello", messages: [], config: {})
  end

  def tool_event(type, child)
    Phronomy::Event.new(
      type: type,
      target_id: invocation.id,
      payload: {tool_invocation_id: child.id}
    )
  end

  it "waits for every approval-resume child before dispatching" do
    first = FakeChild.new(id: "tool-1", status: :awaiting_approval)
    second = FakeChild.new(id: "tool-2", status: :awaiting_approval)
    invocation.tool_invocations = [first, second]
    invocation.begin_approval_resume!(approved: true)

    first.status = :authorized
    invocation.handle_fsm_event(tool_event(:tool_authorized, first))
    expect(invocation.approval_required?).to be(false)
    expect(invocation.ready_to_dispatch?).to be(false)

    second.status = :authorized
    invocation.handle_fsm_event(tool_event(:tool_authorized, second))
    expect(invocation.ready_to_dispatch?).to be(true)
  end

  it "does not treat cancellation during Human rejection as a Tool failure" do
    rejected = FakeChild.new(id: "tool-1", status: :awaiting_approval)
    cancelled = FakeChild.new(id: "tool-2", status: :authorized)
    invocation.tool_invocations = [rejected, cancelled]
    invocation.begin_approval_resume!(approved: false)

    cancelled.status = :cancelled
    invocation.handle_fsm_event(tool_event(:tool_cancelled, cancelled))
    expect(invocation.tool_batch_failed?).to be(false)
    expect(invocation.approval_required?).to be(false)

    rejected.status = :rejected
    invocation.handle_fsm_event(tool_event(:tool_rejected, rejected))
    expect(invocation.tool_batch_rejected?).to be(true)
  end

  # ---------------------------------------------------------------------------
  # Branch coverage: constructor, handle_fsm_event, approval_context,
  # set_graph_metadata, merge_config!
  # ---------------------------------------------------------------------------

  describe "constructor" do
    it "uses id from config when provided" do
      inv = described_class.new(
        agent: agent, input: "hi", messages: [], config: {agent_invocation_id: "custom-id"}
      )
      expect(inv.id).to eq("custom-id")
    end

    it "derives approval_policy from invocation_context when available" do
      policy = ->(_req) { :allow }
      ctx = instance_double(Phronomy::InvocationContext, approval_policy: policy)
      inv = described_class.new(
        agent: agent, input: "hi", messages: [], config: {invocation_context: ctx}
      )
      expect(inv.instance_variable_get(:@approval_policy)).to eq(policy)
    end

    it "uses explicit approval_policy when invocation_context has none" do
      policy = ->(_req) { :reject }
      ctx = instance_double(Phronomy::InvocationContext)
      allow(ctx).to receive(:respond_to?).with(:approval_policy).and_return(false)
      inv = described_class.new(
        agent: agent, input: "hi", messages: [],
        config: {invocation_context: ctx}, approval_policy: policy
      )
      expect(inv.instance_variable_get(:@approval_policy)).to eq(policy)
    end
  end

  describe "#handle_fsm_event" do
    it "ignores non-tool events" do
      event = Phronomy::Event.new(type: :finished, target_id: invocation.id, payload: {})
      expect(invocation.handle_fsm_event(event)).to be false
    end

    it "returns true even when tool_invocation_id is unknown" do
      event = Phronomy::Event.new(
        type: :tool_completed, target_id: invocation.id,
        payload: {tool_invocation_id: "unknown-id"}
      )
      expect(invocation.handle_fsm_event(event)).to be true
    end

    it "propagates error from failed child" do
      error = RuntimeError.new("boom")
      child = FakeChild.new(id: "tool-1", status: :failed, error: error)
      invocation.tool_invocations = [child]
      invocation.handle_fsm_event(tool_event(:tool_failed, child))
      expect(invocation.error).to be(error)
    end

    it "sets rejected when child is rejected" do
      child = FakeChild.new(id: "tool-1", status: :rejected, error: nil)
      invocation.tool_invocations = [child]
      invocation.handle_fsm_event(tool_event(:tool_rejected, child))
      expect(invocation.instance_variable_get(:@rejected)).to be true
    end
  end

  describe "#set_graph_metadata" do
    it "sets session_id from thread_id" do
      invocation.set_graph_metadata(thread_id: "thr-1", phase: :calling_llm)
      expect(invocation.instance_variable_get(:@session_id)).to eq("thr-1")
    end
  end

  describe "#approval_context" do
    it "returns config[:approval_context] when set" do
      inv = described_class.new(
        agent: agent, input: "hi", messages: [],
        config: {approval_context: {role: :admin}}
      )
      expect(inv.approval_context).to eq({role: :admin})
    end

    it "returns empty hash when no invocation_context" do
      inv = described_class.new(agent: agent, input: "hi", messages: [], config: {})
      expect(inv.approval_context).to eq({})
    end

    it "extracts fields from invocation_context" do
      ctx = instance_double(Phronomy::InvocationContext,
        approval_policy: nil, task_id: "t1", parent_task_id: nil)
      allow(ctx).to receive(:respond_to?).and_return(false)
      allow(ctx).to receive(:respond_to?).with(:task_id).and_return(true)
      allow(ctx).to receive(:respond_to?).with(:parent_task_id).and_return(false)
      inv = described_class.new(
        agent: agent, input: "hi", messages: [], config: {invocation_context: ctx}
      )
      result = inv.approval_context
      expect(result[:task_id]).to eq("t1")
    end
  end

  describe "#merge_config!" do
    it "merges new values into config" do
      invocation.merge_config!(metadata: {source: "approval"})
      expect(invocation.instance_variable_get(:@config)[:metadata]).to eq({source: "approval"})
    end

    it "is a no-op with empty hash" do
      original = invocation.instance_variable_get(:@config).dup
      invocation.merge_config!({})
      expect(invocation.instance_variable_get(:@config)).to eq(original)
    end
  end
end
