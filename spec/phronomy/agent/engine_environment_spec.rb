# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::EngineEnvironment do
  let(:environment) { described_class.new }

  def build(agent:, input:, config:, mode: :invoke, on_event: nil, approval_policy: nil, approval_listener: nil)
    invocation = Phronomy::Agent::AgentInvocation.new(agent: agent, input: input, config: config, mode: mode, event_listener: on_event, approval_policy: approval_policy, approval_listener: approval_listener)
    environment.build_agent_session(invocation: invocation)
  end
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-32", version: 1
      model "test-model"
    end
  end
  let(:agent) { agent_class.new }

  describe "authorization resources" do
    it "reads current pool options at submission while retaining its owning Runtime" do
      runtime = Phronomy::Runtime.new
      connection = described_class.new(runtime: runtime)
      token = Phronomy::Concurrency::CancellationToken.new
      expect(Phronomy::Runtime).not_to receive(:instance)
      Phronomy.configure do |c|
        c.authorization_pool_size = 2
        c.authorization_queue_size = 3
      end
      expect(Phronomy::Execution).to receive(:submit).with(runtime: runtime,
        pool_name: :authorization, size: 2, queue_size: 3,
        timeout: nil, cancellation_token: token, on_full: :raise).and_yield
      expect(connection.submit_authorization(timeout: nil, cancellation_token: token) { :first }).to eq(:first)
      Phronomy.configure do |c|
        c.authorization_pool_size = 4
        c.authorization_queue_size = 6
      end
      expect(Phronomy::Execution).to receive(:submit).with(runtime: runtime,
        pool_name: :authorization, size: 4, queue_size: 6,
        timeout: 9, cancellation_token: token, on_full: :raise).and_yield
      expect(connection.submit_authorization(timeout: 9, cancellation_token: token) { :second }).to eq(:second)
    ensure
      runtime&.shutdown
    end
  end

  describe "LLM connection" do
    it "constructs the client without starting resources or selecting a default Runtime" do
      runtime = Phronomy::Runtime.new
      adapter = instance_double(Phronomy::LLMAdapter::Base)
      expect(runtime).not_to receive(:offload)
      expect(Phronomy::Runtime).not_to receive(:instance)
      client = described_class.new(runtime: runtime).build_llm_client(adapter: adapter)
      expect(client).to be_a(Phronomy::LLMAdapter::AsyncClient)
      expect(runtime.__event_loop_if_initialized).to be_nil
    ensure
      runtime&.shutdown
    end

    it "rejects work after its owner stops instead of falling back to a fresh default" do
      runtime = Phronomy::Runtime.new
      adapter = instance_double(Phronomy::LLMAdapter::Base)
      client = described_class.new(runtime: runtime).build_llm_client(adapter: adapter)
      runtime.shutdown
      expect(Phronomy::Runtime).not_to receive(:instance)
      expect(adapter).not_to receive(:complete)
      expect { client.complete_async(Phronomy::LLMAdapter::Request.new(message: "hello")) }
        .to raise_error(Phronomy::RuntimeShutdownError)
    ensure
      runtime&.shutdown
    end
  end

  describe ".build" do
    it "returns a Phronomy::FSMSession" do
      session = build(
        agent: agent,
        input: "hello",
        config: {execution_id: "execution-1"}
      )
      expect(session).to be_a(Phronomy::FSMSession)
      expect(session.instance_variable_get(:@terminal_policy)).to be_nil
    end

    it "lets each FSMSession own a fresh UUID identity" do
      first = build(
        agent: agent, input: "hi", config: {execution_id: "execution-1"}
      )
      second = environment.build_agent_session(
        invocation: first.context,
        resume_event: :resume,
        resume_phase: :suspended
      )
      expect(first.id).to match(/\A[0-9a-f-]{36}\z/)
      expect(second.id).to match(/\A[0-9a-f-]{36}\z/)
      expect(second.id).not_to eq(first.id)
      expect(first.context).not_to respond_to(:id, :session_id)
    end

    it "does not require application generic identity to build a session" do
      session = build(
        agent: agent, input: "hi", config: {execution_id: "execution-1", user_id: "u1"}
      )
      expect(session.id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "sets :suspended as the wait_state (Human approval suspends AgentInvocation)" do
      session = build(
        agent: agent, input: "hi", config: {execution_id: "execution-1"}
      )
      wait_states = session.instance_variable_get(:@wait_state_names)
      expect(wait_states).to include(:suspended)
    end

    it "registers ToolInvocation events and :resume as external events" do
      session = build(
        agent: agent, input: "hi", config: {execution_id: "execution-1"}
      )
      ext = session.instance_variable_get(:@external_events)
      expect(ext.keys).to include(:tool_authorized, :tool_completed, :tool_failed,
        :tool_approval_required, :tool_rejected, :tool_cancelled, :resume)
    end

    it "accepts mode: :stream and on_event" do
      on_event = ->(_event, _event_sink) {}
      session = build(
        agent: agent, input: "hi", config: {execution_id: "execution-1"},
        mode: :stream, on_event: on_event
      )
      expect(session).to be_a(Phronomy::FSMSession)
    end

    it "accepts approval_policy and approval_listener" do
      policy = ->(_req) { :allow }
      listener = ->(_req) {}
      session = build(
        agent: agent, input: "hi", config: {execution_id: "execution-1"},
        approval_policy: policy, approval_listener: listener
      )
      expect(session).to be_a(Phronomy::FSMSession)
    end

    it "includes all expected entry action states" do
      session = build(
        agent: agent, input: "hi", config: {execution_id: "execution-1"}
      )
      declared = session.instance_variable_get(:@declared_states)
      expect(declared).to include(:calling_llm, :waiting_for_tools, :suspended)
    end
  end

  describe ".dispatching_tools_action" do
    it "delegates Tool dispatch to causal durable preparation" do
      coordinator = double("coordinator")
      config = {phronomy_execution_coordinator: coordinator}
      invocation = double("invocation", config: config)
      parent_event_sink = double("parent-event-sink")

      allow(coordinator).to receive(:prepare_tool_dispatch)

      result = Phronomy::Agent::InvocationActions.send(
        :dispatching_tools_action, nil, parent_event_sink, invocation
      )

      expect(result).to be(invocation)
      expect(coordinator).to have_received(:prepare_tool_dispatch)
        .with(invocation, event_sink: parent_event_sink)
    end
  end
end
