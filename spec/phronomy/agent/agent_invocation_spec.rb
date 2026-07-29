# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::AgentInvocation do
  FakeChild = Struct.new(:id, :status, :error, keyword_init: true) do
    def awaiting_approval? = status == :awaiting_approval
    def authorized? = status == :authorized
    def rejected? = status == :rejected
    def failed? = status == :failed
    def cancelled? = status == :cancelled
    def execution_completed? = status == :completed
    def terminal? = %i[completed rejected failed cancelled].include?(status)
    def preflight_settled? = %i[authorized awaiting_approval completed rejected failed cancelled].include?(status)
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
end
