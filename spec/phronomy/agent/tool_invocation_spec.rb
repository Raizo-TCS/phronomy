# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::ToolInvocation do
  ToolCall = Struct.new(:id, :name, :arguments, keyword_init: true)

  let(:tool_class) do
    Class.new(Phronomy::Agent::Context::Capability::Base) do
      tool_name "send_message"
      description "Send a message"
      param :recipients, type: :array, desc: "Recipients"
      param :body, type: :string, desc: "Body"
      redact_params :body

      approval_facts do |arguments, _context|
        {
          recipient_count: arguments[:recipients].size,
          external_domain: "example.net"
        }
      end

      requires_approval do |request|
        request.facts[:recipient_count] > 10
      end

      def execute(recipients:, body:)
        "sent #{body.length} bytes to #{recipients.length} recipients"
      end
    end
  end

  let(:tool) { tool_class.new }
  let(:agent) { instance_double(Phronomy::Agent::Base) }
  let(:tool_call) do
    ToolCall.new(
      id: "call-1",
      name: "send_message",
      arguments: {"recipients" => Array.new(11, "a@example.net"), "body" => "secret"}
    )
  end

  subject(:invocation) do
    described_class.new(
      parent_agent_invocation_id: "agent-1",
      agent: agent,
      tool: tool,
      tool_call: tool_call,
      config: {},
      approval_context: {environment: :production}
    )
  end

  it "validates arguments before evaluating approval facts" do
    invocation.validate!
    outcome = invocation.send(:evaluate_authorization)

    expect(invocation.arguments).to include(body: "secret")
    expect(outcome.decision).to eq(:require_approval)
    expect(outcome.facts).to include(recipient_count: 11)
  end

  it "allows Agent policy to combine Tool facts with Application context" do
    policy = lambda do |request|
      if request.invocation_context[:environment] == :production &&
          request.facts[:recipient_count] > 10
        :reject
      else
        request.default_decision
      end
    end
    invocation = described_class.new(
      parent_agent_invocation_id: "agent-1",
      agent: agent,
      tool: tool,
      tool_call: tool_call,
      config: {},
      approval_policy: policy,
      approval_context: {environment: :production}
    )

    invocation.validate!
    outcome = invocation.send(:evaluate_authorization)

    expect(outcome.decision).to eq(:reject)
  end

  it "redacts sensitive arguments and String-valued facts from UI output" do
    invocation.validate!
    invocation.apply_fsm_action_result(invocation.send(:evaluate_authorization))

    expect(invocation.display_arguments[:body]).to eq("[REDACTED]")
    expect(invocation.display_facts[:recipient_count]).to eq(11)
    expect(invocation.display_facts[:external_domain]).to eq("[REDACTED]")
  end
end
