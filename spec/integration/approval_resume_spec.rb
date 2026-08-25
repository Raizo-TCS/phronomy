# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Group 30: Approval Resume
#
# ACS-16 / CG-09 contract:
# - SUSPENDED is a nonterminal Agent execution state.
# - The original invoke_async Task remains pending through suspension.
# - approval-required notification is delivered through the Agent-incarnation
#   on_event listener and carries execution_id/request id.
# - An accepted approve_async Task is distinct but observes the same logical
#   execution's terminal outcome.
# - Invalid approval fails only that approval Task.

RSpec.describe "Group 30: Approval Resume", :integration do
  after do
    LLMStub.deactivate
    Phronomy.reset_runtime!
  rescue
    nil
  end

  describe "no policy; approved; single approval tool" do
    let(:tool_class) { IntegrationFactors.approval_tool(result_value: "tool_result_001") }
    let(:agent_class) { IntegrationFactors.approval_resume_agent(tool_class) }
    let(:approvals) { Queue.new }
    let(:agent) do
      agent_class.new(
        on_event: ->(event) {
          approvals << event.payload.fetch(:request) if event.type == :approval_required
        }
      )
    end

    before do
      @llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response("approval_required_tool", {query: "run it"}),
        "The tool ran successfully."
      ])
    end

    it "keeps invoke_async pending while the execution is durably suspended" do
      task = agent.invoke_async("Please use the approval tool")
      request = approvals.pop

      expect(task).not_to be_done
      expect(request.execution_id).to be_a(String)
      expect(request.execution_id).not_to be_empty
      expect(agent.persistence.executions.load(request.execution_id).status)
        .to eq(:suspended)
    end

    it "settles original and approval Tasks with the same terminal execution" do
      original = agent.invoke_async("Please use the approval tool")
      request = approvals.pop

      approval = agent.approve_async(
        request.execution_id,
        approval_request_id: request.id,
        approved: true
      )

      expect(approval).not_to equal(original)
      original_result = original.wait_result
      approval_result = approval.wait_result
      expect(original_result[:output]).to be_a(String)
      expect(original_result[:output]).not_to be_empty
      expect(approval_result[:output]).to eq(original_result[:output])
      expect(approval_result[:execution_id]).to eq(original_result[:execution_id])
    end

    it "fails a stale approval without settling the original invocation Task" do
      original = agent.invoke_async("Please use the approval tool")
      request = approvals.pop

      stale = agent.approve_async(
        request.execution_id,
        approval_request_id: "stale",
        approved: true
      )
      expect { stale.wait_result }.to raise_error(ArgumentError, /does not match/)
      expect(original).not_to be_done

      agent.approve_async(
        request.execution_id,
        approval_request_id: request.id,
        approved: true
      ).wait_result
      expect(original.wait_result[:output]).to be_a(String)
    end
  end

  describe "no policy; denied; multiple approval tools" do
    let(:tool_class_a) { IntegrationFactors.approval_tool(result_value: "first_tool_result") }
    let(:tool_class_b) { IntegrationFactors.second_approval_tool(result_value: "second_tool_result") }
    let(:agent_class) { IntegrationFactors.approval_resume_agent(tool_class_a, tool_class_b) }
    let(:approvals) { Queue.new }
    let(:agent) do
      agent_class.new(
        on_event: ->(event) {
          approvals << event.payload.fetch(:request) if event.type == :approval_required
        }
      )
    end

    before do
      @llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response("approval_required_tool", {query: "deny it"})
      ])
    end

    it "returns the same rejected terminal outcome to the original and approval Tasks" do
      original = agent.invoke_async("Try the protected tool")
      request = approvals.pop

      expect(original).not_to be_done

      approval = agent.approve_async(
        request.execution_id,
        approval_request_id: request.id,
        approved: false
      )

      expect(approval.wait_result[:rejected]).to be true
      expect(original.wait_result[:rejected]).to be true
    end
  end

  describe "policy allow; approved; multiple approval tools" do
    let(:tool_class_a) { IntegrationFactors.approval_tool(result_value: "approved_result_a") }
    let(:tool_class_b) { IntegrationFactors.second_approval_tool(result_value: "approved_result_b") }
    let(:agent_class) { IntegrationFactors.approval_resume_agent(tool_class_a, tool_class_b) }
    let(:approvals) { [] }
    let(:agent) do
      agent_class.new(
        on_event: ->(event) {
          approvals << event.payload.fetch(:request) if event.type == :approval_required
        }
      )
    end

    before do
      agent.tool_approval_policy { :allow }
      @llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response("approval_required_tool", {query: "run it"}),
        "Done -- policy allowed the tool."
      ])
    end

    it "does not suspend and does not produce an approval notification" do
      result = agent.invoke("Use the approval tool")

      expect(approvals).to be_empty
      expect(result[:suspended]).to be_falsy
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  describe "policy reject; denied; single approval tool" do
    let(:tool_class) { IntegrationFactors.approval_tool(result_value: "should_not_appear") }
    let(:agent_class) { IntegrationFactors.approval_resume_agent(tool_class) }
    let(:approvals) { [] }
    let(:agent) do
      agent_class.new(
        on_event: ->(event) {
          approvals << event.payload.fetch(:request) if event.type == :approval_required
        }
      )
    end

    before do
      agent.tool_approval_policy { :reject }
      @llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response("approval_required_tool", {query: "deny test"})
      ])
    end

    it "rejects before suspension and returns no text output" do
      result = agent.invoke("Use the approval tool please")

      expect(approvals).to be_empty
      expect(result[:rejected]).to be true
      expect(result[:suspended]).to be_falsy
      expect(result[:output]).to be_nil
    end
  end

  describe "synchronous terminal-waiting wrapper" do
    let(:tool_class) { IntegrationFactors.approval_tool(result_value: "tool_result_sync") }
    let(:agent_class) { IntegrationFactors.approval_resume_agent(tool_class) }

    before do
      @llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response("approval_required_tool", {query: "run sync"}),
        "Sync flow completed."
      ])
    end

    it "receives approval notification through the Agent listener and returns only the final result" do
      agent = nil
      agent = agent_class.new(
        on_event: ->(event) {
          next unless event.type == :approval_required

          request = event.payload.fetch(:request)
          agent.approve_async(
            request.execution_id,
            approval_request_id: request.id,
            approved: true
          )
        }
      )

      result = agent.invoke("Use the protected tool")

      expect(result[:output]).to eq("Sync flow completed.")
      expect(result[:suspended]).to be_falsy
    end
  end
end
