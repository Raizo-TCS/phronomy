# frozen_string_literal: true

require "spec_helper"

class HITLTool < Phronomy::Agent::Context::Capability::Base
  tool_name "hitl_tool"
  description "A tool requiring human approval"
  requires_approval true
  param :value, type: :string, desc: "Input"
  def execute(value:) = "executed: \#{value}"
end

class HITLAgent < Phronomy::Agent::Base
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
  after { Phronomy::Agent::SuspendedSessionRegistry.clear! }

  describe "#invoke with an approval-required tool (no sync handler)" do
    let(:agent) { HITLAgent.new }
    let(:chat_dbl) { build_hitl_chat(tools_hash: {hitl_tool: tool_instance}) }
    before { allow(RubyLLM).to receive(:chat).and_return(chat_dbl) }

    it "returns :suspended => true" do
      expect(agent.invoke("run tool")[:suspended]).to be true
    end

    it "returns :output => nil" do
      expect(agent.invoke("run tool")[:output]).to be_nil
    end

    it "returns a :session_id String" do
      result = agent.invoke("run tool")
      expect(result[:session_id]).to be_a(String)
      expect(result[:session_id]).not_to be_empty
    end

    it "does NOT return :checkpoint key" do
      expect(agent.invoke("run tool")).not_to have_key(:checkpoint)
    end

    it "returns :messages" do
      expect(agent.invoke("run tool")).to have_key(:messages)
    end

    it "stores context in SuspendedSessionRegistry" do
      result = agent.invoke("run tool")
      expect(Phronomy::Agent::SuspendedSessionRegistry.exists?(result[:session_id])).to be true
    end

    it "does NOT suspend when on_approval_required handler is registered" do
      agent.on_approval_required { |_n, _a| true }
      allow(tool_instance).to receive(:call).and_return("executed: hello")
      result = agent.invoke("run tool")
      expect(result[:suspended]).to be_falsy
      expect(result[:output]).to eq("Task complete.")
    end
  end

  describe "#approve (class method)" do
    let(:agent) { HITLAgent.new }
    let(:chat_dbl) { build_hitl_chat(tools_hash: {hitl_tool: tool_instance}, final_response: "Tool ran.") }
    before { allow(RubyLLM).to receive(:chat).and_return(chat_dbl) }
    subject(:session_id) { agent.invoke("run tool")[:session_id] }

    it "returns final output after approval" do
      allow(tool_instance).to receive(:call).and_return("executed: hello")
      expect(HITLAgent.approve(session_id)[:output]).to eq("Tool ran.")
    end

    it "executes the tool call method when approved" do
      expect(tool_instance).to receive(:call).with({"value" => "hello"}).and_return("executed: hello")
      HITLAgent.approve(session_id)
    end

    it "injects tool result into chat via add_message" do
      allow(tool_instance).to receive(:call).and_return("executed: hello")
      HITLAgent.approve(session_id)
      expect(chat_dbl).to have_received(:add_message).with(
        hash_including(role: :tool, content: "executed: hello", tool_call_id: "call_001")
      )
    end

    it "returns :messages" do
      allow(tool_instance).to receive(:call).and_return("r")
      expect(HITLAgent.approve(session_id)).to have_key(:messages)
    end

    it "removes session from SuspendedSessionRegistry after approval" do
      allow(tool_instance).to receive(:call).and_return("r")
      sid = session_id
      HITLAgent.approve(sid)
      expect(Phronomy::Agent::SuspendedSessionRegistry.exists?(sid)).to be false
    end

    it "raises ArgumentError for unknown session_id" do
      expect { HITLAgent.approve("nonexistent") }
        .to raise_error(ArgumentError, /No suspended session/)
    end
  end

  describe "#approve with approved: false (rejection)" do
    let(:agent) { HITLAgent.new }
    let(:chat_dbl) { build_hitl_chat(tools_hash: {hitl_tool: tool_instance}) }
    before { allow(RubyLLM).to receive(:chat).and_return(chat_dbl) }

    it "returns :rejected => true" do
      sid = agent.invoke("run tool")[:session_id]
      expect(agent.approve(sid, approved: false)[:rejected]).to be true
    end

    it "returns :messages" do
      sid = agent.invoke("run tool")[:session_id]
      expect(agent.approve(sid, approved: false)).to have_key(:messages)
    end

    it "does NOT call the tool when rejected" do
      sid = agent.invoke("run tool")[:session_id]
      expect(tool_instance).not_to receive(:call)
      agent.approve(sid, approved: false)
    end
  end
end
