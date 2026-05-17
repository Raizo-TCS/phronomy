# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Group 30: Approval Resume
#
# Pairwise factors:
#   approval_suspension_mode × approval_decision × approval_tool_count
#
# Generated test cases: 4 (all feasible; no infeasible cases)
#
# Infeasible cases: none
#
# LLM required: No (WebMock)
#   All LLM interactions are stubbed via LLMStub.  No real LM Studio
#   connection is required.

RSpec.describe "Group 30: Approval Resume", :integration do
  after { LLMStub.deactivate }

  # ---------------------------------------------------------------------------
  # TC-001: no_handler / approved / single
  #   Agent has one approval-required tool and no on_approval_required handler.
  #   invoke suspends and returns a Checkpoint; resume with approved: true
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

    it "invoke returns a Checkpoint in :checkpoint" do
      result = agent.invoke("Please use the approval tool")
      expect(result[:checkpoint]).to be_a(Phronomy::Agent::Checkpoint)
    end

    it "Checkpoint records the pending tool name" do
      result = agent.invoke("Please use the approval tool")
      expect(result[:checkpoint].pending_tool_name).to eq("approval_required_tool")
    end

    it "resume with approved: true returns :suspended => false" do
      suspend_result = agent.invoke("Please use the approval tool")
      checkpoint = suspend_result[:checkpoint]
      resume_result = agent.resume(checkpoint, approved: true)
      expect(resume_result[:suspended]).to be false
    end

    it "resume with approved: true returns output from the LLM" do
      suspend_result = agent.invoke("Please use the approval tool")
      checkpoint = suspend_result[:checkpoint]
      resume_result = agent.resume(checkpoint, approved: true)
      expect(resume_result[:output]).to be_a(String)
      expect(resume_result[:output]).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: no_handler / denied / multiple
  #   Agent has two approval-required tools and no handler.
  #   invoke suspends on the first approval tool; resume with approved: false
  #   injects a denial message and returns a final response without executing
  #   the tool.
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
      expect(result[:checkpoint].pending_tool_name).to eq("approval_required_tool")
    end

    it "resume with approved: false returns :suspended => false" do
      suspend_result = agent.invoke("Try the first tool")
      resume_result = agent.resume(suspend_result[:checkpoint], approved: false)
      expect(resume_result[:suspended]).to be false
    end

    it "resume with approved: false returns a text output" do
      suspend_result = agent.invoke("Try the first tool")
      resume_result = agent.resume(suspend_result[:checkpoint], approved: false)
      expect(resume_result[:output]).to be_a(String)
      expect(resume_result[:output]).not_to be_empty
    end

    it "resume with approved: false does NOT execute the approval tool" do
      suspend_result = agent.invoke("Try the first tool")
      checkpoint = suspend_result[:checkpoint]
      # Verify the tool is not invoked by asserting its result is NOT in messages.
      resume_result = agent.resume(checkpoint, approved: false)
      tool_messages = resume_result[:messages].select { |m| m.role.to_s == "tool" }
      tool_messages.each do |msg|
        expect(msg.content).not_to include("first_tool_result")
      end
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
        "Done — approval granted synchronously."
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

    it "invoke does not return a Checkpoint" do
      result = agent.invoke("Use the approval tool")
      expect(result[:checkpoint]).to be_nil
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
