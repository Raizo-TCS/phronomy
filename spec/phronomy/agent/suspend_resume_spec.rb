# frozen_string_literal: true

require "spec_helper"

class HITLTool < Phronomy::Agent::Context::Capability::Base
  tool_name "hitl_tool"
  description "A tool requiring human approval"
  requires_approval true
  param :value, type: :string, desc: "Input"
  def execute(value:) = "executed: #{value}"
end

class HITLAgent < Phronomy::Agent::Base
  agent_definition id: "hitl-agent", version: 1
  model "test-model"
  instructions "You are a test assistant."
  tools HITLTool => nil
end

FAKE_HITL_TOKENS = Struct.new(:input, :output, :cached, :cache_creation).new(10, 5, 0, 0)

def build_hitl_chat(tool_name: "hitl_tool", tool_args: {"value" => "hello"},
  tool_call_id: "call_001", final_response: "Task complete.",
  messages_list: [], tools_hash: {})
  stored_hook = nil
  fake_tc = double(
    "ToolCall",
    name: tool_name,
    arguments: tool_args,
    id: tool_call_id,
    thought_signature: nil,
    to_h: {id: tool_call_id, name: tool_name, arguments: tool_args}
  )
  fake_assistant_msg = double(
    "AssistantMessage",
    role: :assistant,
    content: nil,
    tool_calls: [fake_tc],
    tokens: FAKE_HITL_TOKENS,
    tool_call?: true
  )
  final_resp = double("FinalResp", content: final_response, tokens: FAKE_HITL_TOKENS)
  dbl = double("HITLChat")
  allow(dbl).to receive(:with_instructions).and_return(dbl)
  allow(dbl).to receive(:with_tool).and_return(dbl)
  allow(dbl).to receive(:with_temperature).and_return(dbl)
  allow(dbl).to receive(:messages) { messages_list + [fake_assistant_msg] }
  allow(dbl).to receive(:tools) { tools_hash }
  allow(dbl).to receive(:add_message)
  allow(dbl).to receive(:cancellation_token=)
  allow(dbl).to receive(:on_tool_call) { |&block| stored_hook = block }
  allow(dbl).to receive(:before_tool_call) { |&block| stored_hook = block }
  allow(dbl).to receive(:on_tool_result)
  allow(dbl).to receive(:ask) { stored_hook&.call(fake_tc) }
  allow(dbl).to receive(:complete).and_return(final_resp)
  dbl
end

RSpec.describe "Agent FSM HITL (human-in-the-loop approval)" do
  let(:tool_instance) { HITLTool.new }

  after do
    Phronomy.reset_runtime!
  rescue
    nil
  end

  describe "#invoke with an approval-required tool (no policy override)" do
    let(:agent) { HITLAgent.new }
    let(:chat_dbl) { build_hitl_chat(tools_hash: {hitl_tool: tool_instance}) }
    before { allow(RubyLLM).to receive(:chat).and_return(chat_dbl) }

    it "returns :suspended => true" do
      expect(agent.invoke("run tool")[:suspended]).to be true
    end

    it "returns :output => nil" do
      expect(agent.invoke("run tool")[:output]).to be_nil
    end

    it "returns an :execution_id String" do
      result = agent.invoke("run tool")
      expect(result[:execution_id]).to be_a(String)
      expect(result[:execution_id]).not_to be_empty
    end

    it "returns an approval request owned by the Agent execution" do
      result = agent.invoke("run tool")
      request = result.fetch(:approval_request)
      expect(request.id).to be_a(String)
      expect(request.execution_id).to eq(result.fetch(:execution_id))
      expect(request).not_to respond_to(:agent_invocation_id)
      expect(request.to_h).not_to have_key(:agent_invocation_id)

      durable = agent.persistence.executions.load(result.fetch(:execution_id))
      expect(durable.approval_request["execution_id"])
        .to eq(result.fetch(:execution_id))
      expect(durable.approval_request).not_to have_key("agent_invocation_id")
    end

    it "has a suspended execution in persistence" do
      agent.invoke("run tool")
      expect(
        agent.persistence.executions.list_active(agent.agent_id).any? { |e|
          e.status == :suspended
        }
      ).to be true
    end

    it "does NOT suspend when tool_approval_policy returns :allow" do
      agent.tool_approval_policy { :allow }
      allow(tool_instance).to receive(:call).and_return("executed: hello")
      result = agent.invoke("run tool")
      expect(result[:suspended]).to be_falsy
      expect(result[:output]).to eq("Task complete.")
    end
  end

  describe "#approve (instance method)" do
    let(:agent) { HITLAgent.new }
    let(:chat_dbl) do
      build_hitl_chat(
        tools_hash: {hitl_tool: tool_instance},
        final_response: "Tool ran."
      )
    end
    before { allow(RubyLLM).to receive(:chat).and_return(chat_dbl) }

    def invoke_and_get_ids
      result = agent.invoke("run tool")
      [result[:execution_id], result[:approval_request].id]
    end

    it "returns final output after approval" do
      execution_id, request_id = invoke_and_get_ids
      allow(tool_instance).to receive(:call).and_return("executed: hello")
      expect(
        agent.approve(execution_id, approval_request_id: request_id)[:output]
      ).to eq("Tool ran.")
    end

    it "execution is no longer active after approval" do
      execution_id, request_id = invoke_and_get_ids
      allow(tool_instance).to receive(:call).and_return("r")
      agent.approve(execution_id, approval_request_id: request_id)
      expect(agent.persistence.executions.list_active(agent.agent_id)).to be_empty
    end

    it "raises ExecutionRehydrationRequiredError for an execution with no live execution owner" do
      expect {
        agent.approve("nonexistent-exec", approval_request_id: "none")
      }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    end
  end

  describe "#approve with approved: false (rejection)" do
    let(:agent) { HITLAgent.new }
    let(:chat_dbl) { build_hitl_chat(tools_hash: {hitl_tool: tool_instance}) }
    before { allow(RubyLLM).to receive(:chat).and_return(chat_dbl) }

    def invoke_and_get_ids
      result = agent.invoke("run tool")
      [result[:execution_id], result[:approval_request].id]
    end

    it "returns :rejected => true" do
      execution_id, request_id = invoke_and_get_ids
      expect(
        agent.approve(
          execution_id,
          approval_request_id: request_id,
          approved: false
        )[:rejected]
      ).to be true
    end

    it "does NOT call the tool when rejected" do
      execution_id, request_id = invoke_and_get_ids
      expect(tool_instance).not_to receive(:call)
      agent.approve(
        execution_id,
        approval_request_id: request_id,
        approved: false
      )
    end
  end
end
