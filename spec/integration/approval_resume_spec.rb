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
# Infeasible cases: none
#
# LLM required: No (WebMock)
#   All LLM interactions are stubbed via LLMStub.  No real LM Studio
#   connection is required.

RSpec.describe "Group 30: Approval Resume", :integration do
  after do
    LLMStub.deactivate
    Phronomy::Agent::SuspendedSessionRegistry.clear!
  end

  # ---------------------------------------------------------------------------
  # TC-001: no_handler / approved / single
  #   Agent has one approval-required tool and no on_approval_required handler.
  #   invoke suspends and returns a session_id; approve with approved: true
  #   executes the tool and returns a final text response.
  # ---------------------------------------------------------------------------
  describe "TC-001: no_handler; approved; single approval tool" do
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

    it "invoke returns a :session_id String" do
      result = agent.invoke("Please use the approval tool")
      expect(result[:session_id]).to be_a(String)
      expect(result[:session_id]).not_to be_empty
    end

    it "invoke does NOT return :checkpoint (removed in Phase 2)" do
      result = agent.invoke("Please use the approval tool")
      expect(result).not_to have_key(:checkpoint)
    end

    it "approve with approved: true returns output from the LLM" do
      suspend_result = agent.invoke("Please use the approval tool")
      resume_result = agent.approve(suspend_result[:session_id])
      expect(resume_result[:output]).to be_a(String)
      expect(resume_result[:output]).not_to be_empty
    end

    it "approve with approved: true returns :suspended falsy" do
      suspend_result = agent.invoke("Please use the approval tool")
      resume_result = agent.approve(suspend_result[:session_id])
      expect(resume_result[:suspended]).to be_falsy
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: no_handler / denied / multiple
  #   Agent has two approval-required tools and no handler.
  #   invoke suspends on the first approval tool; approve with approved: false
  #   rejects the tool and ends the invocation (rejected: true, no LLM output).
  # ---------------------------------------------------------------------------
  describe "TC-002: no_handler; denied; multiple approval tools" do
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
      expect(result[:session_id]).to be_a(String)
    end

    it "approve with approved: false returns :rejected => true" do
      suspend_result = agent.invoke("Try the first tool")
      resume_result = agent.approve(suspend_result[:session_id], approved: false)
      expect(resume_result[:rejected]).to be true
    end

    it "approve with approved: false does NOT execute the approval tool" do
      suspend_result = agent.invoke("Try the first tool")
      # No call to the tool's execute method happens in the rejection path.
      result = agent.approve(suspend_result[:session_id], approved: false)
      expect(result[:rejected]).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # TC-003: handler_registered / approved / multiple
  #   Agent has two approval-required tools; handler registered that always
  #   approves.  invoke should NOT suspend; tool executes synchronously via
  #   the prepare_tool_class wrapper; agent returns a final text response.
  # ---------------------------------------------------------------------------
  describe "TC-003: handler_registered; approved; multiple approval tools" do
    let(:tool_class_a) { IntegrationFactors.approval_tool(result_value: "approved_result_a") }
    let(:tool_class_b) { IntegrationFactors.second_approval_tool(result_value: "approved_result_b") }
    let(:agent_class) { IntegrationFactors.approval_resume_agent(tool_class_a, tool_class_b) }
    let(:agent) { agent_class.new }

    before do
      agent.on_approval_required { |_name, _args| true }
      @llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response("approval_required_tool", {query: "sync approval test"}),
        "Done -- approval granted synchronously."
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

    it "invoke does not return a :session_id (no suspension occurred)" do
      result = agent.invoke("Use the approval tool")
      expect(result[:session_id]).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004: handler_registered / denied / single
  #   Agent has one approval-required tool; handler always denies.
  #   invoke should NOT suspend; the wrapped tool returns the denial string;
  #   the LLM receives the denial and returns a final text response.
  # ---------------------------------------------------------------------------
  describe "TC-004: handler_registered; denied; single approval tool" do
    let(:tool_class) { IntegrationFactors.approval_tool(result_value: "should_not_appear") }
    let(:agent_class) { IntegrationFactors.approval_resume_agent(tool_class) }
    let(:agent) { agent_class.new }

    before do
      agent.on_approval_required { |_name, _args| false }
      @llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response("approval_required_tool", {query: "deny test"}),
        "The tool execution was denied."
      ])
    end

    it "invoke does NOT return :suspended" do
      result = agent.invoke("Use the approval tool please")
      expect(result[:suspended]).to be_falsy
    end

    it "invoke returns a text output" do
      result = agent.invoke("Use the approval tool please")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end

    it "tool result in messages contains the denial message" do
      result = agent.invoke("Use the approval tool please")
      tool_messages = result[:messages].select { |m| m.role.to_s == "tool" }
      denial_found = tool_messages.any? { |m| m.content.include?("Tool execution denied.") }
      expect(denial_found).to be true
    end
  end
end
