# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::AgentInvocationSessionBuilder do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) { model "test-model" }
  end
  let(:agent) { agent_class.new }

  describe ".build" do
    it "returns a Phronomy::FSMSession" do
      session = described_class.build(
        agent: agent,
        input: "hello",
        messages: [],
        config: {thread_id: "t-1"}
      )
      expect(session).to be_a(Phronomy::FSMSession)
    end

    it "uses agent_invocation_id (UUID) as session id, independent of thread_id" do
      session = described_class.build(
        agent: agent, input: "hi", messages: [], config: {thread_id: "my-id"}
      )
      # session.id is the AgentInvocation UUID, not the conversation thread_id
      expect(session.id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "generates a UUID when thread_id is not provided" do
      session = described_class.build(
        agent: agent, input: "hi", messages: [], config: {}
      )
      expect(session.id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "sets :suspended as the wait_state (Human approval suspends AgentInvocation)" do
      session = described_class.build(
        agent: agent, input: "hi", messages: [], config: {}
      )
      wait_states = session.instance_variable_get(:@wait_state_names)
      expect(wait_states).to include(:suspended)
    end

    it "registers ToolInvocation events and :resume as external events" do
      session = described_class.build(
        agent: agent, input: "hi", messages: [], config: {}
      )
      ext = session.instance_variable_get(:@external_events)
      expect(ext.keys).to include(:tool_authorized, :tool_completed, :tool_failed,
        :tool_approval_required, :tool_rejected, :tool_cancelled, :resume)
    end

    it "accepts mode: :stream and on_event" do
      on_event = ->(e) {}
      session = described_class.build(
        agent: agent, input: "hi", messages: [], config: {},
        mode: :stream, on_event: on_event
      )
      expect(session).to be_a(Phronomy::FSMSession)
    end
  end
end
