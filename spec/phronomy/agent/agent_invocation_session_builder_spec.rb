# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::AgentInvocationSessionBuilder do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-32", version: 1
      model "test-model"
    end
  end
  let(:agent) { agent_class.new }

  describe ".build" do
    it "returns a Phronomy::FSMSession" do
      session = described_class.build(
        agent: agent,
        input: "hello",
        config: {execution_id: "execution-1"}
      )
      expect(session).to be_a(Phronomy::FSMSession)
    end

    it "lets each FSMSession own a fresh UUID identity" do
      first = described_class.build(
        agent: agent, input: "hi", config: {execution_id: "execution-1"}
      )
      second = described_class.build_for_resume(
        agent_invocation: first.context,
        resume_event: :resume,
        resume_phase: :suspended
      )
      expect(first.id).to match(/\A[0-9a-f-]{36}\z/)
      expect(second.id).to match(/\A[0-9a-f-]{36}\z/)
      expect(second.id).not_to eq(first.id)
      expect(first.context).not_to respond_to(:id, :session_id)
    end

    it "does not require application generic identity to build a session" do
      session = described_class.build(
        agent: agent, input: "hi", config: {execution_id: "execution-1", user_id: "u1"}
      )
      expect(session.id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "sets :suspended as the wait_state (Human approval suspends AgentInvocation)" do
      session = described_class.build(
        agent: agent, input: "hi", config: {execution_id: "execution-1"}
      )
      wait_states = session.instance_variable_get(:@wait_state_names)
      expect(wait_states).to include(:suspended)
    end

    it "registers ToolInvocation events and :resume as external events" do
      session = described_class.build(
        agent: agent, input: "hi", config: {execution_id: "execution-1"}
      )
      ext = session.instance_variable_get(:@external_events)
      expect(ext.keys).to include(:tool_authorized, :tool_completed, :tool_failed,
        :tool_approval_required, :tool_rejected, :tool_cancelled, :resume)
    end

    it "accepts mode: :stream and on_event" do
      on_event = ->(_event, _event_sink) {}
      session = described_class.build(
        agent: agent, input: "hi", config: {execution_id: "execution-1"},
        mode: :stream, on_event: on_event
      )
      expect(session).to be_a(Phronomy::FSMSession)
    end

    it "accepts approval_policy and approval_listener" do
      policy = ->(_req) { :allow }
      listener = ->(_req) {}
      session = described_class.build(
        agent: agent, input: "hi", config: {execution_id: "execution-1"},
        approval_policy: policy, approval_listener: listener
      )
      expect(session).to be_a(Phronomy::FSMSession)
    end

    it "includes all expected entry action states" do
      session = described_class.build(
        agent: agent, input: "hi", config: {execution_id: "execution-1"}
      )
      declared = session.instance_variable_get(:@declared_states)
      expect(declared).to include(:calling_llm, :waiting_for_tools, :suspended)
    end
  end

  describe ".dispatching_tools_action" do
    it "dispatches every authorized ToolInvocation in the batch" do
      first = double("first", id: "tool-1", authorized?: true)
      second = double("second", id: "tool-2", authorized?: true)
      rejected = double("rejected", id: "tool-3", authorized?: false)
      invocation = double("invocation", tool_invocations: [first, second, rejected])
      runtime = instance_double(Phronomy::Runtime)
      first_session = double("first-session")
      second_session = double("second-session")

      allow(Phronomy::Agent::ToolInvocationSessionBuilder)
        .to receive(:build_for_resume)
        .and_return(first_session, second_session)
      allow(described_class).to receive(:register_child_session)

      parent_event_sink = double("parent-event-sink")
      result = described_class.send(
        :dispatching_tools_action, runtime, parent_event_sink, invocation
      )

      expect(result).to be(invocation)
      expect(Phronomy::Agent::ToolInvocationSessionBuilder)
        .to have_received(:build_for_resume).twice
      expect(described_class).to have_received(:register_child_session)
        .with(runtime, first, first_session, parent_event_sink)
      expect(described_class).to have_received(:register_child_session)
        .with(runtime, second, second_session, parent_event_sink)
    end
  end
end
