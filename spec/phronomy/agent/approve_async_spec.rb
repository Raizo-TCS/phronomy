# frozen_string_literal: true

require "spec_helper"

# Reuse HITL fixtures if already defined (e.g., when full suite runs).
# Otherwise define locally for isolated runs.
unless defined?(HITLTool)
  class HITLTool < Phronomy::Agent::Context::Capability::Base
    tool_name "hitl_tool"
    description "A tool requiring human approval"
    requires_approval true
    param :value, type: :string, desc: "Input"
    def execute(value:) = "executed: #{value}"
  end
end

unless defined?(HITLAgentForApproveAsync)
  class HITLAgentForApproveAsync < Phronomy::Agent::Base
    agent_definition id: "hitl-agent-approve-async", version: 1
    model "test-model"
    instructions "You are a test assistant."
    tools HITLTool
  end
end

FAKE_APPROVE_ASYNC_TOKENS = Struct.new(:input, :output, :cached, :cache_creation).new(10, 5, 0, 0)

def build_approve_async_chat(tool_instance:, final_response: "resumed")
  stored_hook = nil
  fake_tc = double(
    "ToolCall",
    name: "hitl_tool",
    arguments: {"value" => "hello"},
    id: "call_001",
    thought_signature: nil,
    to_h: {id: "call_001", name: "hitl_tool", arguments: {"value" => "hello"}}
  )
  final_resp = double("FinalResp", content: final_response, tokens: FAKE_APPROVE_ASYNC_TOKENS)
  dbl = double("HITLChat")
  allow(dbl).to receive(:with_instructions).and_return(dbl)
  allow(dbl).to receive(:with_tool).and_return(dbl)
  allow(dbl).to receive(:with_temperature).and_return(dbl)
  allow(dbl).to receive(:messages) { [] }
  allow(dbl).to receive(:tools) { {hitl_tool: tool_instance} }
  allow(dbl).to receive(:add_message)
  allow(dbl).to receive(:cancellation_token=)
  allow(dbl).to receive(:on_tool_call) { |&block| stored_hook = block }
  allow(dbl).to receive(:before_tool_call) { |&block| stored_hook = block }
  allow(dbl).to receive(:on_tool_result)
  allow(dbl).to receive(:ask) { stored_hook&.call(fake_tc) }
  allow(dbl).to receive(:complete).and_return(final_resp)
  dbl
end

RSpec.describe Phronomy::Agent::Base do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-38", version: 1
      instructions "test"
      model "gpt-4o-mini"
    end
  end
  let(:agent) { agent_class.new }

  describe "#approve EventLoop re-entry guard" do
    it "raises SchedulerReentrancyError when called from the EventLoop thread" do
      event_loop = double("event_loop", current?: true)
      runtime = double("runtime", event_loop: event_loop)
      allow(Phronomy::Runtime).to receive(:instance).and_return(runtime)

      expect do
        agent.approve(
          "invocation-1",
          approval_request_id: "request-1",
          approved: true
        )
      end.to raise_error(
        Phronomy::SchedulerReentrancyError,
        /approve_async/
      )
    end
  end

  describe "#approve_async" do
    let(:tool_instance) { HITLTool.new }
    let(:agent) { HITLAgentForApproveAsync.new }
    let(:chat) { build_approve_async_chat(tool_instance: tool_instance) }

    before { allow(RubyLLM).to receive(:chat).and_return(chat) }

    def invoke_and_suspend
      agent.invoke("run tool")
    end

    it "returns immediately with a pending Task and settles after resume" do
      result = invoke_and_suspend
      execution_id = result[:execution_id]
      request_id = result[:approval_request].id
      allow(tool_instance).to receive(:call).and_return("done")

      task = agent.approve_async(execution_id, approval_request_id: request_id)
      expect(task).to be_a(Phronomy::Task)
      expect(task.wait_result[:output]).to eq("resumed")
    end

    it "is callable while the EventLoop is current (no SchedulerReentrancyError)" do
      result = invoke_and_suspend
      execution_id = result[:execution_id]
      request_id = result[:approval_request].id
      allow(tool_instance).to receive(:call).and_return("done")

      # approve_async must not raise SchedulerReentrancyError even when the EventLoop
      # reports current? == true (unlike approve which wraps with _check_scheduler_reentrancy).
      event_loop = Phronomy::Runtime.instance.event_loop
      allow(event_loop).to receive(:current?).and_return(true)
      expect {
        task = agent.approve_async(execution_id, approval_request_id: request_id)
        expect(task).to be_a(Phronomy::Task)
      }.not_to raise_error(Phronomy::SchedulerReentrancyError)
    end

    it "returns a failed Task when execution_id is unknown" do
      task = agent.approve_async("nonexistent-exec", approval_request_id: "none")
      expect(task).to be_a(Phronomy::Task)
      expect { task.wait_result }.to raise_error(Phronomy::Persistence::NotFoundError)
    end
  end
end
