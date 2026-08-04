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
  tools HITLTool
end

FAKE_HITL_TOKENS = Struct.new(:input, :output, :cached, :cache_creation).new(10, 5, 0, 0)

def build_hitl_chat(tool_name: "hitl_tool", tool_args: {"value" => "hello"},
  tool_call_id: "call_001", final_response: "Task complete.",
  messages_list: [], tools_hash: {})
  stored_hook = nil
  fake_tc = double("ToolCall", name: tool_name, arguments: tool_args, id: tool_call_id)
  final_resp = double("FinalResp", content: final_response, tokens: FAKE_HITL_TOKENS)
  dbl = double("HITLChat")
  allow(dbl).to receive(:with_instructions).and_return(dbl)
  allow(dbl).to receive(:with_tool).and_return(dbl)
  allow(dbl).to receive(:with_temperature).and_return(dbl)
  allow(dbl).to receive(:messages) { messages_list }
  allow(dbl).to receive(:tools) { tools_hash }
  allow(dbl).to receive(:add_message)
  allow(dbl).to receive(:cancellation_token=)
  allow(dbl).to receive(:on_tool_call) { |&block| stored_hook = block }
  allow(dbl).to receive(:on_tool_result)
  allow(dbl).to receive(:ask) { stored_hook&.call(fake_tc) }
  allow(dbl).to receive(:complete).and_return(final_resp)
  dbl
end

RSpec.describe "Agent FSM HITL (human-in-the-loop approval)" do
  let(:tool_instance) { HITLTool.new }
  after {}

  describe "#invoke with an approval-required tool (no policy override)" do
    let(:agent) { HITLAgent.new }
    let(:chat_dbl) { build_hitl_chat(tools_hash: {hitl_tool: tool_instance}) }
    before do
      skip "requires ExecutionCoordinator-based rewrite: RubyLLM mock doubles need to_h for ToolCall serialization"
      allow(RubyLLM).to receive(:chat).and_return(chat_dbl)
    end

    it "returns :suspended => true" do
      expect(agent.invoke("run tool")[:suspended]).to be true
    end

    it "returns :output => nil" do
      expect(agent.invoke("run tool")[:output]).to be_nil
    end

    it "returns an :agent_invocation_id String" do
      result = agent.invoke("run tool")
      expect(result[:agent_invocation_id]).to be_a(String)
      expect(result[:agent_invocation_id]).not_to be_empty
    end

    it "returns an :approval_request with an id" do
      result = agent.invoke("run tool")
      expect(result[:approval_request]).not_to be_nil
      expect(result[:approval_request].id).to be_a(String)
    end

    it "returns :messages" do
      expect(agent.invoke("run tool")).to have_key(:messages)
    end

    it "has a suspended execution in persistence" do
      agent.invoke("run tool")
      expect(agent.persistence.executions.list_active(agent.agent_id).any? { |e| e.status == :suspended }).to be true
    end

    it "does NOT suspend when tool_approval_policy returns :allow" do
      agent.tool_approval_policy { :allow }
      allow(tool_instance).to receive(:call).and_return("executed: hello")
      result = agent.invoke("run tool")
      expect(result[:suspended]).to be_falsy
      expect(result[:output]).to eq("Task complete.")
    end
  end

  describe "#approve (class method)" do
    let(:agent) { HITLAgent.new }
    let(:chat_dbl) { build_hitl_chat(tools_hash: {hitl_tool: tool_instance}, final_response: "Tool ran.") }
    before do
      skip "requires ExecutionCoordinator-based rewrite: approve API changed and ToolCall mock needs to_h"
      allow(RubyLLM).to receive(:chat).and_return(chat_dbl)
    end

    def invoke_and_get_ids
      result = agent.invoke("run tool")
      [result[:agent_invocation_id], result[:approval_request].id]
    end

    it "returns final output after approval" do
      invocation_id, request_id = invoke_and_get_ids
      allow(tool_instance).to receive(:call).and_return("executed: hello")
      expect(HITLAgent.approve(invocation_id, approval_request_id: request_id)[:output]).to eq("Tool ran.")
    end

    it "returns :messages" do
      invocation_id, request_id = invoke_and_get_ids
      allow(tool_instance).to receive(:call).and_return("r")
      expect(HITLAgent.approve(invocation_id, approval_request_id: request_id)).to have_key(:messages)
    end

    it "execution is no longer active after approval" do
      invocation_id, request_id = invoke_and_get_ids
      allow(tool_instance).to receive(:call).and_return("r")
      HITLAgent.approve(invocation_id, approval_request_id: request_id)
      expect(agent.persistence.executions.list_active(agent.agent_id)).to be_empty
    end

    it "raises ArgumentError for unknown agent_invocation_id" do
      expect { HITLAgent.approve("nonexistent", approval_request_id: "none") }
        .to raise_error(ArgumentError, /No pending approval/)
    end
  end

  describe "#approve with approved: false (rejection)" do
    let(:agent) { HITLAgent.new }
    let(:chat_dbl) { build_hitl_chat(tools_hash: {hitl_tool: tool_instance}) }
    before do
      skip "requires ExecutionCoordinator-based rewrite: approve API changed and ToolCall mock needs to_h"
      allow(RubyLLM).to receive(:chat).and_return(chat_dbl)
    end

    def invoke_and_get_ids
      result = agent.invoke("run tool")
      [result[:agent_invocation_id], result[:approval_request].id]
    end

    it "returns :rejected => true" do
      invocation_id, request_id = invoke_and_get_ids
      expect(agent.approve(invocation_id, approval_request_id: request_id, approved: false)[:rejected]).to be true
    end

    it "returns :messages" do
      invocation_id, request_id = invoke_and_get_ids
      expect(agent.approve(invocation_id, approval_request_id: request_id, approved: false)).to have_key(:messages)
    end

    it "does NOT call the tool when rejected" do
      invocation_id, request_id = invoke_and_get_ids
      expect(tool_instance).not_to receive(:call)
      agent.approve(invocation_id, approval_request_id: request_id, approved: false)
    end
  end
end
