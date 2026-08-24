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

  describe "Execution-scoped Task suspension semantics" do
    let(:agent) { HITLAgent.new }
    let(:chat_dbl) { build_hitl_chat(tools_hash: {hitl_tool: tool_instance}) }
    before { allow(RubyLLM).to receive(:chat).and_return(chat_dbl) }

    def invoke_and_capture_approval(agent)
      approvals = Queue.new
      events = Queue.new
      task = agent.invoke_async(
        "run tool",
        on_tool_approval_required: ->(request) { approvals << request },
        on_event: ->(event) { events << event }
      )
      [task, approvals.pop, events]
    end

    it "keeps the original Task pending while durable execution is suspended" do
      task, request, = invoke_and_capture_approval(agent)

      expect(task).to be_a(Phronomy::Task)
      expect(task).not_to be_done
      expect(request.execution_id).to be_a(String)
      expect(request.execution_id).not_to be_empty

      durable = agent.persistence.executions.load(request.execution_id)
      expect(durable.status).to eq(:suspended)
      expect(durable.approval_request["execution_id"]).to eq(request.execution_id)
      expect(durable.approval_request).not_to have_key("agent_invocation_id")
    end

    it "delivers approval_required without settling the original Task" do
      task, request, events = invoke_and_capture_approval(agent)
      # :tool_call events are published before :approval_required; drain until found.
      event = events.pop
      event = events.pop until event.type == :approval_required

      expect(event.payload.fetch(:request).id).to eq(request.id)
      expect(task).not_to be_done
    end

    it "settles original and accepted approval Tasks with the same terminal result" do
      task, request, = invoke_and_capture_approval(agent)
      allow(tool_instance).to receive(:call).and_return("executed: hello")

      approval_task = agent.approve_async(
        request.execution_id,
        approval_request_id: request.id
      )

      original_result = task.wait_result
      approval_result = approval_task.wait_result
      expect(original_result[:output]).to eq("Task complete.")
      expect(approval_result[:output]).to eq("Task complete.")
      expect(approval_result[:execution_id]).to eq(original_result[:execution_id])
      expect(agent.persistence.executions.list_active(agent.agent_id)).to be_empty
    end

    it "keeps the original Task pending when a stale approval fails" do
      task, request, = invoke_and_capture_approval(agent)

      stale = agent.approve_async(
        request.execution_id,
        approval_request_id: "stale-request"
      )
      expect { stale.wait_result }.to raise_error(ArgumentError, /does not match/)
      expect(task).not_to be_done

      allow(tool_instance).to receive(:call).and_return("executed: hello")
      agent.approve_async(
        request.execution_id,
        approval_request_id: request.id
      ).wait_result
      expect(task.wait_result[:output]).to eq("Task complete.")
    end

    it "does NOT suspend when tool_approval_policy returns :allow" do
      agent.tool_approval_policy { :allow }
      allow(tool_instance).to receive(:call).and_return("executed: hello")
      result = agent.invoke("run tool")
      expect(result[:suspended]).to be_falsy
      expect(result[:output]).to eq("Task complete.")
    end
  end

  describe "#invoke terminal-waiting HITL wrapper" do
    let(:agent) { HITLAgent.new }
    let(:chat_dbl) do
      build_hitl_chat(
        tools_hash: {hitl_tool: tool_instance},
        final_response: "Tool ran."
      )
    end
    before do
      allow(RubyLLM).to receive(:chat).and_return(chat_dbl)
      allow(tool_instance).to receive(:call).and_return("executed: hello")
    end

    it "accepts on_tool_approval_required and waits through suspension" do
      request_seen = Queue.new
      result = agent.invoke(
        "run tool",
        on_tool_approval_required: ->(request) {
          request_seen << request
          agent.approve_async(
            request.execution_id,
            approval_request_id: request.id
          )
        }
      )

      request = request_seen.pop
      expect(request.execution_id).to eq(result[:execution_id])
      expect(result[:output]).to eq("Tool ran.")
      expect(result[:suspended]).to be_falsy
    end
  end

  describe "#approve with approved: false (rejection)" do
    let(:agent) { HITLAgent.new }
    let(:chat_dbl) { build_hitl_chat(tools_hash: {hitl_tool: tool_instance}) }
    before { allow(RubyLLM).to receive(:chat).and_return(chat_dbl) }

    it "returns :rejected => true without executing the tool" do
      approvals = Queue.new
      original = agent.invoke_async(
        "run tool",
        on_tool_approval_required: ->(request) { approvals << request }
      )
      request = approvals.pop

      expect(tool_instance).not_to receive(:call)
      approval = agent.approve_async(
        request.execution_id,
        approval_request_id: request.id,
        approved: false
      )

      expect(approval.wait_result[:rejected]).to be true
      expect(original.wait_result[:rejected]).to be true
    end
  end
end
