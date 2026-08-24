# frozen_string_literal: true

require "spec_helper"

RSpec.describe "ACS-11 Tool authorization worker snapshot boundary" do
  AuthorizationSnapshotToolCall = Struct.new(:id, :name, :arguments)

  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "acs11-approval-snapshot-agent", version: 7

      def initialize(agent_id:)
        @agent_id = agent_id.to_s.freeze
      end
    end
  end

  let(:agent) do
    agent_class.new(agent_id: "acs11-agent-instance")
  end

  let(:tool_class) do
    Class.new(Phronomy::Agent::Context::Capability::Base) do
      tool_name "snapshot_tool"
      description "Tool used by the ACS-11 authorization snapshot contract"
      param :value, type: :string, desc: "Input"

      approval_facts do |arguments, context|
        {
          value_length: arguments.fetch(:value).length,
          environment: context[:environment]
        }
      end

      requires_approval do |request|
        request.facts[:value_length] > 3
      end

      def execute(value:)
        value
      end
    end
  end

  let(:tool) { tool_class.new }

  let(:tool_call) do
    AuthorizationSnapshotToolCall.new(
      "provider-tool-call-1",
      "snapshot_tool",
      {"value" => "hello"}
    )
  end

  def build_invocation(
    approval_policy: nil,
    approval_context: {environment: :production}
  )
    Phronomy::Agent::ToolInvocation.new(
      execution_id: "execution-1",
      agent: agent,
      tool: tool,
      tool_call: tool_call,
      config: {},
      approval_policy: approval_policy,
      approval_context: approval_context,
      id: "tool-invocation-1"
    ).tap(&:validate!)
  end

  it "captures Agent and Tool worker input as values/behaviors without live objects" do
    invocation = build_invocation
    command = invocation.send(:authorization_command)

    expect(command.members).to include(
      :agent_id,
      :agent_definition_id,
      :agent_definition_version,
      :approval_facts_callable,
      :approval_requirement
    )
    expect(command.members).not_to include(:agent)
    expect(command.members).not_to include(:tool)
    expect(command.to_h.values).not_to include(agent)
    expect(command.to_h.values).not_to include(tool)
    expect(command.to_h.values).not_to include(invocation)

    expect(command.agent_id).to eq("acs11-agent-instance")
    expect(command.agent_definition_id).to eq("acs11-approval-snapshot-agent")
    expect(command.agent_definition_version).to eq(7)
    expect(command.tool_name).to eq("snapshot_tool")
    expect(command.approval_facts_callable).to respond_to(:call)
    expect(command.approval_requirement).to respond_to(:call)
  end

  it "passes only value metadata to application approval policy" do
    captured = nil
    policy = lambda do |request|
      captured = request
      request.default_decision
    end
    invocation = build_invocation(approval_policy: policy)

    outcome = invocation.send(:evaluate_authorization)

    expect(outcome.decision).to eq(:require_approval)
    expect(captured.agent_id).to eq("acs11-agent-instance")
    expect(captured.agent_definition_id).to eq("acs11-approval-snapshot-agent")
    expect(captured.agent_definition_version).to eq(7)
    expect(captured.execution_id).to eq("execution-1")
    expect(captured.tool_name).to eq("snapshot_tool")
    expect(captured).not_to respond_to(:agent)
    expect(captured).not_to respond_to(:tool)
  end

  it "does not consult the live Tool after the authorization command is captured" do
    invocation = build_invocation
    command = invocation.send(:authorization_command)

    allow(tool).to receive(:requires_approval)
      .and_raise("worker consulted live Tool")

    evaluator = Phronomy::Agent::ToolInvocation
    outcome = evaluator.send(:evaluate_authorization_command, command)

    expect(outcome.decision).to eq(:require_approval)
    expect(outcome.facts).to include(value_length: 5)
  end

  it "captures empty authorization behavior values without a live Tool" do
    invocation = Phronomy::Agent::ToolInvocation.new(
      execution_id: "execution-no-tool",
      agent: agent,
      tool: nil,
      tool_call: AuthorizationSnapshotToolCall.new(
        "provider-tool-call-missing",
        "missing_tool",
        {}
      ),
      config: {},
      id: "tool-invocation-missing"
    )
    invocation.validate!

    command = invocation.send(:authorization_command)

    expect(command.approval_facts_callable).to be_nil
    expect(command.approval_requirement).to be(false)
    expect(command.tool_schema).to eq({})
  end

  it "validates required Agent and execution identity on value-only policy input" do
    attributes = {
      agent_id: "agent-1",
      agent_definition_id: "agent-definition",
      agent_definition_version: 1,
      execution_id: "execution-1",
      tool_name: "snapshot_tool",
      tool_schema: {},
      tool_invocation_id: "tool-invocation-1",
      tool_call_id: "provider-tool-call-1",
      arguments: {}
    }

    expect {
      Phronomy::Agent::ApprovalEvaluationRequest.new(
        **attributes.merge(agent_id: "")
      )
    }.to raise_error(ArgumentError, /agent_id/)

    expect {
      Phronomy::Agent::ApprovalEvaluationRequest.new(
        **attributes.merge(agent_definition_id: "")
      )
    }.to raise_error(ArgumentError, /agent_definition_id/)

    expect {
      Phronomy::Agent::ApprovalEvaluationRequest.new(
        **attributes.merge(execution_id: "")
      )
    }.to raise_error(ArgumentError, /execution_id/)
  end

  it "deep-copies and freezes Hash Array and String command data" do
    source = {
      environment: :production,
      nested: [+"mutable"]
    }
    invocation = build_invocation(approval_context: source)
    command = invocation.send(:authorization_command)

    expect(command.approval_context).to be_frozen
    expect(command.approval_context[:nested]).to be_frozen
    expect(command.approval_context[:nested].first).to be_frozen
    expect(command.approval_context[:nested].first).to eq("mutable")

    source[:nested].first.replace("changed")
    expect(command.approval_context[:nested].first).to eq("mutable")
  end

  it "rejects Phronomy-managed live objects nested in worker value data" do
    invocation = build_invocation(
      approval_context: {
        environment: :production,
        forbidden_live_agent: agent
      }
    )

    expect {
      invocation.send(:authorization_command)
    }.to raise_error(
      Phronomy::ConfigurationError,
      /Phronomy-managed live domain object/
    )
  end

  it "rejects Phronomy::EventLoop nested in approval_context" do
    runtime = Phronomy::Runtime.new
    invocation = build_invocation(
      approval_context: {event_loop: runtime.event_loop}
    )
    expect {
      invocation.send(:authorization_command)
    }.to raise_error(Phronomy::ConfigurationError, /Phronomy-managed live domain object/)
  ensure
    runtime&.shutdown(timeout: 2)
  end

  it "rejects Phronomy::FSMSession nested in approval_context" do
    runtime = Phronomy::Runtime.new
    sink = Phronomy::FSMSession::EventSink.new(event_loop: runtime.event_loop)
    inv = build_invocation(approval_context: {sink: sink})
    expect {
      inv.send(:authorization_command)
    }.to raise_error(Phronomy::ConfigurationError, /Phronomy-managed live domain object/)
  ensure
    runtime&.shutdown(timeout: 2)
  end

  it "rejects Phronomy::Concurrency::CancellationToken nested in approval_context" do
    token = Phronomy::Concurrency::CancellationToken.new
    inv = build_invocation(approval_context: {token: token})
    expect {
      inv.send(:authorization_command)
    }.to raise_error(Phronomy::ConfigurationError, /Phronomy-managed live domain object/)
  end

  it "rejects a live Phronomy tool as requires_approval behavior handle" do
    expect(tool).to respond_to(:call)
    allow(tool).to receive(:requires_approval).and_return(tool)
    inv = build_invocation

    expect {
      inv.send(:authorization_command)
    }.to raise_error(Phronomy::ConfigurationError, /requires_approval.*Phronomy-managed/)
  end

  it "keeps opaque Application-owned custom values permitted for ACS-11" do
    opaque = Object.new
    captured_request = nil
    policy = lambda do |request|
      captured_request = request
      request.default_decision
    end
    invocation = build_invocation(
      approval_policy: policy,
      approval_context: {
        environment: :production,
        opaque: opaque
      }
    )
    command = invocation.send(:authorization_command)
    outcome = invocation.send(:evaluate_authorization)

    expect(command.approval_context[:opaque]).to be(opaque)
    expect(captured_request.invocation_context[:opaque]).to be(opaque)
    expect(outcome.decision).to eq(:require_approval)
  end

  it "permits an Application-defined callable as requires_approval handle" do
    callable = ->(request) { request.requires_approval? }
    allow(tool).to receive(:requires_approval).and_return(callable)
    inv = build_invocation

    expect {
      inv.send(:authorization_command)
    }.not_to raise_error
  end
end
