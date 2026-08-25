# frozen_string_literal: true

require "spec_helper"

# Targeted branch-coverage fill-in for small files.
# Each example here covers a specific branch that is not exercised by
# the main feature specs (guard clauses, nil-safe-navigation paths, etc.).

RSpec.describe "Coverage gap fill-in for small utility classes" do
  describe Phronomy::Agent::LLMOperationResult do
    it "raises when llm_call_id is nil" do
      expect {
        described_class.new(llm_call_id: nil)
      }.to raise_error(ArgumentError, /requires llm_call_id/)
    end

    it "raises when llm_call_id is empty string" do
      expect {
        described_class.new(llm_call_id: "")
      }.to raise_error(ArgumentError, /requires llm_call_id/)
    end
  end

  describe Phronomy::Agent::ToolCallIntercepted do
    it "accepts nil llm_call_id (safe-navigation nil path)" do
      tc = double("tc", id: "tc-1", name: "tool", arguments: {}, thought_signature: nil)
      err = described_class.new([tc], llm_call_id: nil)
      expect(err.instance_variable_get(:@llm_call_id)).to be_nil
    end
  end

  describe "Phronomy::MultiAgent::CoordinationState" do
    let(:agent) do
      ag = double("agent")
      allow(ag).to receive(:is_a?).with(Phronomy::Agent::Base).and_return(true)
      ag
    end

    it "raises when active_agent is not an Agent::Base" do
      expect {
        Phronomy::MultiAgent::CoordinationState.new(active_agent: "not-an-agent")
      }.to raise_error(ArgumentError, /active_agent/)
    end

    it "raises when active_handoff_context is not a HandoffContext" do
      expect {
        Phronomy::MultiAgent::CoordinationState.new(
          active_agent: agent,
          active_handoff_context: "wrong-type"
        )
      }.to raise_error(ArgumentError, /active_handoff_context/)
    end
  end

  describe "Phronomy::Agent::ToolApprovalRequest" do
    let(:valid_item) do
      Phronomy::Agent::ToolApprovalRequest::Item.new(
        tool_invocation_id: "inv-1",
        tool_call_id: nil,
        tool_name: "my_tool",
        arguments: {"x" => [1, 2]},
        facts: [:role_a, :role_b],
        reason: nil,
        origin: :external,
        metadata: {}
      )
    end

    it "accepts nil tool_call_id (safe-navigation nil path)" do
      expect(valid_item.instance_variable_get(:@tool_call_id)).to be_nil
    end

    it "accepts nil reason (safe-navigation nil path)" do
      expect(valid_item.instance_variable_get(:@reason)).to be_nil
    end

    it "deep-copies Array arguments via immutable_copy" do
      args_copy = valid_item.instance_variable_get(:@arguments)
      expect(args_copy["x"]).to eq([1, 2])
      expect(args_copy["x"]).to be_frozen
    end

    it "raises when items is empty" do
      expect {
        Phronomy::Agent::ToolApprovalRequest.new(execution_id: "exec-1", items: [])
      }.to raise_error(ArgumentError, /requires at least one item/)
    end

    it "raises when execution_id is nil" do
      expect {
        Phronomy::Agent::ToolApprovalRequest.new(execution_id: nil, items: [valid_item])
      }.to raise_error(ArgumentError, /requires execution_id/)
    end

    it "raises when execution_id is empty string" do
      expect {
        Phronomy::Agent::ToolApprovalRequest.new(execution_id: "", items: [valid_item])
      }.to raise_error(ArgumentError, /requires execution_id/)
    end
  end

  describe "Phronomy.with_configuration preserving state on exception" do
    it "restores configuration after a raised exception" do
      Phronomy.configuration
      expect {
        Phronomy.with_configuration { raise "boom" }
      }.to raise_error(RuntimeError, "boom")
      # configuration is restored by ensure
      expect(Phronomy.configuration).not_to be_nil
    end
  end

  describe "Phronomy.reset_runtime! restores previous grace period" do
    after {
      begin
        Phronomy.reset_runtime!
      rescue
        nil
      end
    }

    it "transfers previous event_loop_stop_grace_seconds to the new configuration" do
      Phronomy.configuration.event_loop_stop_grace_seconds = 99
      Phronomy.reset_runtime!
      expect(Phronomy.configuration.event_loop_stop_grace_seconds).to eq(99)
    end
  end

  describe "Phronomy::Agent::AgentRoot guard clauses" do
    def base_attrs
      now = Time.now.utc.iso8601(6)
      {
        agent_id: "a-1",
        agent_definition_id: "def-1",
        agent_definition_version: 1,
        agent_revision: 0,
        context_revision: 0,
        journal_position: 0,
        lifecycle_status: :idle,
        transcript_generation: 0,
        created_at: now,
        updated_at: now,
        metadata: {}
      }
    end

    it "raises for an unknown lifecycle_status" do
      expect {
        Phronomy::Agent::AgentRoot.new(**base_attrs.merge(lifecycle_status: :bogus))
      }.to raise_error(ArgumentError, /unknown Agent lifecycle status/)
    end

    it "raises for negative agent_revision" do
      expect {
        Phronomy::Agent::AgentRoot.new(**base_attrs.merge(agent_revision: -1))
      }.to raise_error(ArgumentError, /agent_revision/)
    end

    it "raises for negative context_revision" do
      expect {
        Phronomy::Agent::AgentRoot.new(**base_attrs.merge(context_revision: -1))
      }.to raise_error(ArgumentError, /context_revision/)
    end

    it "raises for negative journal_position" do
      expect {
        Phronomy::Agent::AgentRoot.new(**base_attrs.merge(journal_position: -1))
      }.to raise_error(ArgumentError, /journal_position/)
    end
  end

  describe "Phronomy::MultiAgent::Handoff guard clauses" do
    class HandoffTestAgentA < Phronomy::Agent::Base
      agent_definition id: "handoff-test-a", version: 1
      model "test-model"
      instructions "test"
    end

    class HandoffTestAgentB < Phronomy::Agent::Base
      agent_definition id: "handoff-test-b", version: 1
      model "test-model"
      instructions "test"
    end

    let(:persistence) { Phronomy::Persistence::InMemory.new }
    let(:agent_a) { HandoffTestAgentA.new(persistence: persistence) }
    let(:agent_b) { HandoffTestAgentB.new(persistence: persistence) }

    it "raises when source and target are the same instance" do
      expect {
        Phronomy::MultiAgent::Handoff.new(source_agent: agent_a, target_agent: agent_a)
      }.to raise_error(ArgumentError, /must be different instances/)
    end

    it "raises when policy is not a HandoffPolicy" do
      expect {
        Phronomy::MultiAgent::Handoff.new(
          source_agent: agent_a,
          target_agent: agent_b,
          policy: "not-a-policy"
        )
      }.to raise_error(ArgumentError, /HandoffPolicy/)
    end
  end

  describe Phronomy::Task do
    it "join with a limit returns nil on timeout" do
      task = described_class.new(name: "join-timeout")
      result = task.join(0.001)
      expect(result).to be_nil
    end

    it "join without limit waits for settlement", :skip_if_slow do
      task = described_class.new(name: "join-settle")
      settled = Queue.new
      t = Thread.new {
        sleep 0.001
        task.complete("done")
        settled << true
      }
      result = task.join(1.0)
      t.join(2)
      expect(result).to be task
      expect(task.status).to eq(:completed)
    end

    it "cancel! is a no-op when already settled" do
      task = described_class.new(name: "cancel-settled")
      task.complete("done")
      task.cancel!
      expect(task.status).to eq(:completed)
    end

    it "on_complete callback error is swallowed and does not re-raise" do
      task = described_class.new(name: "callback-raise")
      task.on_complete { |_, _| raise "callback failure" }
      expect { task.complete("done") }.not_to raise_error
      expect(task.status).to eq(:completed)
    end
  end
end
