# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Group 30: Approval Resume
#
# ACS-16 / CG-06 contract:
# - SUSPENDED is a nonterminal Agent execution state.
# - The original invoke_async Task remains pending through suspension.
# - approval-required notification carries execution_id/request id.
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
    let(:agent) { agent_class.new }

    before do
      @llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response("approval_required_tool", {query: "run it"}),
        "The tool ran successfully."
      ])
    end

    it "keeps invoke_async pending while the execution is durably suspended" do
      approvals = Queue.new
      task = agent.invoke_async(
        "Please use the approval tool",
        on_tool_approval_required: ->(request) { approvals << request }
      )
      request = approvals.pop

      expect(task).not_to be_done
      expect(request.execution_id).to be_a(String)
      expect(request.execution_id).not_to be_empty
      expect(agent.persistence.executions.load(request.execution_id).status)
        .to eq(:suspended)
    end

    it "settles original and approval Tasks with the same terminal execution" do
      approvals = Queue.new
      original = agent.invoke_async(
        "Please use the approval tool",
        on_tool_approval_required: ->(request) { approvals << request }
      )
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
      approvals = Queue.new
      original = agent.invoke_async(
        "Please use the approval tool",
        on_tool_approval_required: ->(request) { approvals << request }
      )
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

  describe "no policy; denied" do
    let(:tool_class) { IntegrationFactors.approval_tool(result_value: "should_not_run") }
    let(:agent_class) { IntegrationFactors.approval_resume_agent(tool_class) }
    let(:agent) { agent_class.new }

    before do
      @llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response("approval_required_tool", {query: "deny it"})
      ])
    end

    it "returns the same rejected terminal outcome to both Tasks" do
      approvals = Queue.new
      original = agent.invoke_async(
        "Try the protected tool",
        on_tool_approval_required: ->(request) { approvals << request }
      )
      request = approvals.pop
      approval = agent.approve_async(
        request.execution_id,
        approval_request_id: request.id,
        approved: false
      )

      expect(approval.wait_result[:rejected]).to be true
      expect(original.wait_result[:rejected]).to be true
    end
  end

  describe "policy allow" do
    let(:tool_class) { IntegrationFactors.approval_tool(result_value: "approved_result") }
    let(:agent_class) { IntegrationFactors.approval_resume_agent(tool_class) }
    let(:agent) { agent_class.new }

    before do
      agent.tool_approval_policy { :allow }
      @llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response("approval_required_tool", {query: "run it"}),
        "Done -- policy allowed the tool."
      ])
    end

    it "does not produce a suspension notification and completes normally" do
      approvals = []
      result = agent.invoke(
        "Use the approval tool",
        on_tool_approval_required: ->(request) { approvals << request }
      )

      expect(approvals).to be_empty
      expect(result[:output]).to be_a(String)
      expect(result[:suspended]).to be_falsy
    end
  end

  describe "synchronous terminal-waiting wrapper" do
    let(:tool_class) { IntegrationFactors.approval_tool(result_value: "tool_result_sync") }
    let(:agent_class) { IntegrationFactors.approval_resume_agent(tool_class) }
    let(:agent) { agent_class.new }

    before do
      @llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response("approval_required_tool", {query: "run sync"}),
        "Sync flow completed."
      ])
    end

    it "accepts approval notification and returns only the final result" do
      result = agent.invoke(
        "Use the protected tool",
        on_tool_approval_required: ->(request) {
          agent.approve_async(
            request.execution_id,
            approval_request_id: request.id,
            approved: true
          )
        }
      )

      expect(result[:output]).to eq("Sync flow completed.")
      expect(result[:suspended]).to be_falsy
    end
  end
end
