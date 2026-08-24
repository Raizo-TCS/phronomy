# frozen_string_literal: true

require "spec_helper"

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
    tools HITLTool => nil
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
  fake_assistant_msg = double(
    "AssistantMessage",
    role: :assistant,
    content: nil,
    tool_calls: [fake_tc],
    tokens: FAKE_APPROVE_ASYNC_TOKENS,
    tool_call?: true
  )
  final_resp = double("FinalResp", content: final_response, tokens: FAKE_APPROVE_ASYNC_TOKENS)
  dbl = double("HITLChat")
  allow(dbl).to receive(:with_instructions).and_return(dbl)
  allow(dbl).to receive(:with_tool).and_return(dbl)
  allow(dbl).to receive(:with_temperature).and_return(dbl)
  allow(dbl).to receive(:messages) { [fake_assistant_msg] }
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

  after do
    Phronomy.reset_runtime!
  rescue
    nil
  end

  describe "#approve EventLoop re-entry guard" do
    it "raises EventLoopReentrancyError when called from the EventLoop thread" do
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
        Phronomy::EventLoopReentrancyError,
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

    it "resumes the same live Agent owner without exposing mutable Runtime state" do
      result = invoke_and_suspend
      execution_id = result[:execution_id]
      request_id = result[:approval_request].id
      owner = Phronomy::Runtime.instance.__agent_execution_owner(execution_id)

      expect(owner.agent).to be(agent)
      expect(owner.status).to eq(:suspended)
      expect(owner).not_to respond_to(:invocation)
      expect(owner).not_to respond_to(:execution)

      allow(tool_instance).to receive(:call).and_return("done")
      agent.approve_async(
        execution_id,
        approval_request_id: request_id
      ).wait_result
    end

    it "is callable while the EventLoop is current" do
      result = invoke_and_suspend
      execution_id = result[:execution_id]
      request_id = result[:approval_request].id
      allow(tool_instance).to receive(:call).and_return("done")

      event_loop = Phronomy::Runtime.instance.event_loop
      allow(event_loop).to receive(:current?).and_return(true)

      task = agent.approve_async(execution_id, approval_request_id: request_id)
      expect(task).to be_a(Phronomy::Task)

      allow(event_loop).to receive(:current?).and_call_original
      expect(task.wait_result[:output]).to eq("resumed")
    end

    it "returns a failed Task requiring durable rehydration when execution_id has no live owner" do
      task = agent.approve_async("nonexistent-exec", approval_request_id: "none")
      expect(task).to be_a(Phronomy::Task)
      expect { task.wait_result }
        .to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    end

    it "does not route approval through another Agent instance's live coordinator" do
      result = invoke_and_suspend
      execution_id = result[:execution_id]
      request_id = result[:approval_request].id
      other = HITLAgentForApproveAsync.new

      task = other.approve_async(
        execution_id,
        approval_request_id: request_id
      )

      expect { task.wait_result }.to raise_error(
        ArgumentError,
        /not a suspended execution of this agent/
      )
      expect(Phronomy::Runtime.instance.__agent_execution_owner(execution_id).status)
        .to eq(:suspended)
    end
  end

  describe ".live_for_execution" do
    let(:tool_instance) { HITLTool.new }
    let(:persistence) { Phronomy::Persistence::InMemory.new }
    let(:agent) do
      HITLAgentForApproveAsync.new(persistence: persistence)
    end
    let(:chat) { build_approve_async_chat(tool_instance: tool_instance) }

    before { allow(RubyLLM).to receive(:chat).and_return(chat) }

    def invoke_and_suspend
      agent.invoke("run tool")
    end

    it "returns the same live owner Agent through Agent::Base" do
      result = invoke_and_suspend
      execution_id = result[:execution_id]
      owner = Phronomy::Runtime.instance.__agent_execution_owner(execution_id)

      resolved = Phronomy::Agent::Base.live_for_execution(execution_id)

      expect(resolved).to be(agent)
      expect(resolved).to be(owner.agent)
    end

    it "returns the same live owner Agent through its concrete Agent class" do
      result = invoke_and_suspend
      execution_id = result[:execution_id]

      resolved = HITLAgentForApproveAsync.live_for_execution(execution_id)

      expect(resolved).to be(agent)
    end

    it "does not load Agent or Execution state from Persistence" do
      result = invoke_and_suspend
      execution_id = result[:execution_id]

      expect(persistence.executions).not_to receive(:load)
      expect(persistence.agents).not_to receive(:load)

      expect(HITLAgentForApproveAsync.live_for_execution(execution_id)).to be(agent)
    end

    it "raises ExecutionRehydrationRequiredError when no live owner exists" do
      expect do
        Phronomy::Agent::Base.live_for_execution("missing-execution")
      end.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    end

    it "raises ArgumentError when the live owner is not an instance of the receiver class" do
      result = invoke_and_suspend
      execution_id = result[:execution_id]

      other_class = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "other-class-agent", version: 1
        model "test-model"
        instructions "other"
      end

      expect do
        other_class.live_for_execution(execution_id)
      end.to raise_error(
        ArgumentError,
        /belongs to HITLAgentForApproveAsync/
      )
    end
  end
end
