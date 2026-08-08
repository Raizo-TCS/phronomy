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
        config: {thread_id: "t-1"}
      )
      expect(session).to be_a(Phronomy::FSMSession)
    end

    it "uses agent_invocation_id (UUID) as session id, independent of thread_id" do
      session = described_class.build(
        agent: agent, input: "hi", config: {thread_id: "my-id"}
      )
      expect(session.id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "generates a UUID when thread_id is not provided" do
      session = described_class.build(
        agent: agent, input: "hi", config: {}
      )
      expect(session.id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "sets :suspended as the wait_state (Human approval suspends AgentInvocation)" do
      session = described_class.build(
        agent: agent, input: "hi", config: {}
      )
      wait_states = session.instance_variable_get(:@wait_state_names)
      expect(wait_states).to include(:suspended)
    end

    it "registers ToolInvocation events and :resume as external events" do
      session = described_class.build(
        agent: agent, input: "hi", config: {}
      )
      ext = session.instance_variable_get(:@external_events)
      expect(ext.keys).to include(:tool_authorized, :tool_completed, :tool_failed,
        :tool_approval_required, :tool_rejected, :tool_cancelled, :resume)
    end

    it "accepts mode: :stream and on_event" do
      on_event = ->(e) {}
      session = described_class.build(
        agent: agent, input: "hi", config: {},
        mode: :stream, on_event: on_event
      )
      expect(session).to be_a(Phronomy::FSMSession)
    end

    it "accepts approval_policy and approval_listener" do
      policy = ->(_req) { :allow }
      listener = ->(_req) {}
      session = described_class.build(
        agent: agent, input: "hi", config: {},
        approval_policy: policy, approval_listener: listener
      )
      expect(session).to be_a(Phronomy::FSMSession)
    end

    it "includes all expected entry action states" do
      session = described_class.build(
        agent: agent, input: "hi", config: {}
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

      result = described_class.send(:dispatching_tools_action, runtime, invocation)

      expect(result).to be(invocation)
      expect(Phronomy::Agent::ToolInvocationSessionBuilder)
        .to have_received(:build_for_resume).twice
      expect(described_class).to have_received(:register_child_session)
        .with(runtime, first, first_session)
      expect(described_class).to have_received(:register_child_session)
        .with(runtime, second, second_session)
    end
  end
end
