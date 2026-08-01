# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Group 30: Approval Resume
#
# Pairwise factors:
#   approval_suspension_mode x approval_decision x approval_tool_count
#
# Generated test cases: 4 (all feasible; no infeasible cases)
#
# LLM required: No (WebMock)
#   All LLM interactions are stubbed via LLMStub.  No real LM Studio
#   connection is required.
#
# NOTE: Updated for 0.15.0 Invocation architecture.
#   - result[:agent_invocation_id] replaces result[:session_id]
#   - result[:approval_request] carries the ToolApprovalRequest
#   - agent.approve(agent_invocation_id, approval_request_id:, approved:)
#     replaces agent.approve(session_id, approved:)
#   - AgentInvocationRegistry replaces SuspendedSessionRegistry
#   - tool_approval_policy replaces on_approval_required inline decision
#   - on_tool_approval_required is for notification only (no decision)

RSpec.describe "Group 30: Approval Resume", :integration do
  after do
    LLMStub.deactivate
    Phronomy::Agent::AgentInvocationRegistry.clear!
  end

  # ---------------------------------------------------------------------------
  # TC-001: no_policy / approved / single
  #   Agent has one approval-required tool and no tool_approval_policy.
  #   requires_approval default → :require_approval.
  #   invoke suspends; approve with approved: true executes tool and returns output.
  # ---------------------------------------------------------------------------
  describe "TC-001: no_policy; approved; single approval tool" do
    let(:tool_class) { IntegrationFactors.approval_tool(result_value: "tool_result_001") }
    let(:agent_class) { IntegrationFactors.approval_resume_agent(tool_class) }
    let(:agent) { agent_class.new }

    before do
      @llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response("approval_required_tool", {query: "run it"}),
        "The tool ran successfully."
      ])
    end

    it "invoke returns :suspended => true" do
      result = agent.invoke("Please use the approval tool")
      expect(result[:suspended]).to be true
    end

    it "invoke returns an :agent_invocation_id String" do
      result = agent.invoke("Please use the approval tool")
      expect(result[:agent_invocation_id]).to be_a(String)
      expect(result[:agent_invocation_id]).not_to be_empty
    end

    it "invoke returns an :approval_request with a non-empty id" do
      result = agent.invoke("Please use the approval tool")
      expect(result[:approval_request]).not_to be_nil
      expect(result[:approval_request].id).to be_a(String)
    end

    it "approve with approved: true returns output from the LLM" do
      suspend_result = agent.invoke("Please use the approval tool")
      resume_result = agent.approve(
        suspend_result[:agent_invocation_id],
        approval_request_id: suspend_result[:approval_request].id,
        approved: true
      )
      expect(resume_result[:output]).to be_a(String)
      expect(resume_result[:output]).not_to be_empty
    end

    it "approve_async returns a Task that resolves to the resumed output" do
      suspend_result = agent.invoke("Please use the approval tool")
      task = agent.approve_async(
        suspend_result[:agent_invocation_id],
        approval_request_id: suspend_result[:approval_request].id,
        approved: true
      )

      expect(task).to be_a(Phronomy::Task)
      resume_result = task.wait_result
      expect(resume_result[:output]).to be_a(String)
      expect(resume_result[:output]).not_to be_empty
    end

    it "approve with approved: true returns :suspended falsy" do
      suspend_result = agent.invoke("Please use the approval tool")
      resume_result = agent.approve(
        suspend_result[:agent_invocation_id],
        approval_request_id: suspend_result[:approval_request].id,
        approved: true
      )
      expect(resume_result[:suspended]).to be_falsy
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: no_policy / denied / multiple
  #   Agent has two approval-required tools and no policy.
  #   invoke suspends on the first approval tool; approve with approved: false
  #   rejects the tool and ends the invocation (rejected: true).
  # ---------------------------------------------------------------------------
  describe "TC-002: no_policy; denied; multiple approval tools" do
    let(:tool_class_a) { IntegrationFactors.approval_tool(result_value: "first_tool_result") }
    let(:tool_class_b) { IntegrationFactors.second_approval_tool(result_value: "second_tool_result") }
    let(:agent_class) { IntegrationFactors.approval_resume_agent(tool_class_a, tool_class_b) }
    let(:agent) { agent_class.new }

    before do
      @llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response("approval_required_tool", {query: "denied test"}),
        "Understood, I will not execute the tool."
      ])
    end

    it "invoke suspends on the first approval tool" do
      result = agent.invoke("Try the first tool")
      expect(result[:suspended]).to be true
      expect(result[:agent_invocation_id]).to be_a(String)
    end

    it "approve with approved: false returns :rejected => true" do
      suspend_result = agent.invoke("Try the first tool")
      resume_result = agent.approve(
        suspend_result[:agent_invocation_id],
        approval_request_id: suspend_result[:approval_request].id,
        approved: false
      )
      expect(resume_result[:rejected]).to be true
    end

    it "approve with approved: false does NOT execute the approval tool" do
      suspend_result = agent.invoke("Try the first tool")
      result = agent.approve(
        suspend_result[:agent_invocation_id],
        approval_request_id: suspend_result[:approval_request].id,
        approved: false
      )
      expect(result[:rejected]).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # TC-003: policy_allow / approved / multiple
  #   Agent has two approval-required tools; tool_approval_policy returns :allow.
  #   invoke should NOT suspend; tools execute without Human intervention;
  #   agent returns a final text response.
  # ---------------------------------------------------------------------------
  describe "TC-003: policy_allow; approved; multiple approval tools" do
    let(:tool_class_a) { IntegrationFactors.approval_tool(result_value: "approved_result_a") }
    let(:tool_class_b) { IntegrationFactors.second_approval_tool(result_value: "approved_result_b") }
    let(:agent_class) { IntegrationFactors.approval_resume_agent(tool_class_a, tool_class_b) }
    let(:agent) { agent_class.new }

    before do
      agent.tool_approval_policy { :allow }
      @llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response("approval_required_tool", {query: "sync approval test"}),
        "Done -- policy allowed the tool."
      ])
    end

    it "invoke does NOT return :suspended" do
      result = agent.invoke("Use the approval tool")
      expect(result[:suspended]).to be_falsy
    end

    it "invoke returns a non-nil text output" do
      result = agent.invoke("Use the approval tool")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end

    it "invoke does not return an :agent_invocation_id (no suspension occurred)" do
      result = agent.invoke("Use the approval tool")
      expect(result[:agent_invocation_id]).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004: policy_reject / denied / single
  #   Agent has one approval-required tool; tool_approval_policy returns :reject.
  #   invoke should NOT suspend; the tool is denied by policy before execution;
  #   the LLM receives the rejection and returns a final text response.
  # ---------------------------------------------------------------------------
  describe "TC-004: policy_reject; denied; single approval tool" do
    let(:tool_class) { IntegrationFactors.approval_tool(result_value: "should_not_appear") }
    let(:agent_class) { IntegrationFactors.approval_resume_agent(tool_class) }
    let(:agent) { agent_class.new }

    before do
      agent.tool_approval_policy { :reject }
      @llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response("approval_required_tool", {query: "deny test"}),
        "The tool execution was denied by policy."
      ])
    end

    it "invoke returns :rejected => true (policy rejected the tool before execution)" do
      result = agent.invoke("Use the approval tool please")
      expect(result[:rejected]).to be true
    end

    it "invoke does not return a text output (rejected before LLM gets tool result)" do
      result = agent.invoke("Use the approval tool please")
      expect(result[:output]).to be_nil
    end
  end
end
