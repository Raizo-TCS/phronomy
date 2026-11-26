# frozen_string_literal: true

require "spec_helper"
require_relative "../../integration/support/hosted_subagent"

RSpec.describe "Native parent approval recovery before decision persistence" do
  include_context "a native child requiring approval"
  let(:effects) { [] }
  let(:approval_tool) do
    recorded = effects
    Class.new(Phronomy::Tool::Base) do
      tool_name "approval_required_tool"
      description "Records one explicitly approved operation"
      param :query, type: :string, desc: "Protected input"
      requires_approval true
      define_method(:execute) do |query:|
        recorded << query
        "approved #{query}"
      end
    end
  end
  let(:parent_class) do
    worker, protected_tool = child_class, approval_tool
    Class.new(Phronomy::MultiAgent::Orchestrator) do
      agent_definition id: "native-parent-approval-capture", version: 1
      model IntegrationFactors::LM_MODEL_30
      provider :openai
      tools protected_tool => nil
      subagent :worker, worker
    end
  end

  before do
    RubyLLM.configure do |configuration|
      configuration.openai_protocol = :chat_completions
      configuration.openai_api_key = "test"
    end
    @runtime = Phronomy::Runtime.instance
  end
  after { @runtime.shutdown(timeout: 0.03, cancel_grace: 0.2) }

  def result_of(task) = task.wait_result(timeout: 8)

  def durable_snapshot
    stores.agent.coordinator.atomic do |scope|
      execution = stores.agent.executions.load(root_id)
      reference = execution.metadata.dig("execution_extension", "state_ref")
      [stores.agent.agents.load(parent.agent_id).to_h, execution.to_h,
        stores.agent.journals.head(parent.agent_id),
        stores.agent.retained_references(agent_id: parent.agent_id, scope: scope).map(&:to_h),
        stores.agent.cancellation_requested?(agent_id: parent.agent_id, execution_id: root_id, scope: scope),
        stores.multi_agent.contents.fetch(reference)]
    end
  end

  %i[native_capture decision_content].each do |boundary|
    it "restores the native own approval wait after a #{boundary} failure and requires a fresh decision" do
      recorder = LLMStub.activate(responses: [protected_call, "parent completed"])
      reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: root_id)
      parent.start_hosted(reservation: reservation, input: "run")
      request = Timeout.timeout(8) { events.pop }
      expect(request.execution_id).to eq(root_id)
      before = durable_snapshot
      reference = before.fetch(1).dig("metadata", "execution_extension", "state_ref")
      transactions = 0
      content_fault = boundary == :decision_content
      allow(stores.agent).to receive(:transaction).and_wrap_original do |original, &write|
        transactions += 1
        original.call do |records, scope|
          if content_fault
            content_fault = false
            allow(records.contents).to receive(:put).and_raise(IOError, "native approval decision content unavailable")
          end
          write.call(records, scope)
        end
      end
      allow(Phronomy::Agent::ApprovalPersistenceEvidence).to receive(:capture).and_call_original
      if boundary == :native_capture
        allow(stores.multi_agent.contents).to receive(:fetch_json).with(reference)
          .and_raise(IOError, "native approval authority content unavailable")
      end

      decision = parent.approve_async(root_id, approval_request_id: request.id, approved: true)
      failure = recovery = nil
      expect { result_of(decision) }.to raise_error(Phronomy::Agent::ApprovalRecoveryError) do |error|
        failure, recovery = error, error.recovery
      end
      expect(parent.pending_approval_recovery(execution_id: root_id)).to equal(recovery)
      expect(parent.__execution_environment.registry.agent_execution_admitted?(parent.agent_id)).to be(true)
      expect { parent.unload! }.to raise_error(Phronomy::AgentBusyError)
      expect(durable_snapshot).to eq(before)
      expect(effects).to be_empty
      expect(recorder.calls.size).to eq(1)

      if boundary == :native_capture
        expect(transactions).to eq(0)
        expect(Phronomy::Agent::ApprovalPersistenceEvidence).not_to have_received(:capture)
        unavailable = parent.reconcile_approval(recovery: recovery)
        expect(unavailable.outcome).to eq(:unavailable)
        expect(unavailable.physical_complete?).to be(true)
        expect(unavailable.application_state).to eq(:pending)
        expect(unavailable.continuation_state).to eq(:pending)
        expect(transactions).to eq(0)
        allow(stores.multi_agent.contents).to receive(:fetch_json).and_call_original
      else
        expect(transactions).to eq(1)
        expect(Phronomy::Agent::ApprovalPersistenceEvidence).to have_received(:capture).once
      end

      transactions = 0
      restored = parent.reconcile_approval(recovery: recovery)
      expect(restored.outcome).to eq(:confirmed_pre), restored.error&.cause&.full_message
      expect(restored.physical_complete?).to be(true)
      expect(restored.application_state).to eq(:applied)
      expect(restored.continuation_state).to eq(:restored)
      expect(restored).to be_resolved
      expect(restored.execution_task).to be_nil
      expect(transactions).to eq(0)
      expect(durable_snapshot).to eq(before)
      expect(parent.pending_approval_recovery(execution_id: root_id)).to be_nil
      expect(parent.__execution_environment.registry.agent_execution_admitted?(parent.agent_id)).to be(true)
      expect(effects).to be_empty
      expect(recorder.calls.size).to eq(1)
      expect { result_of(decision) }.to raise_error { |error| expect(error).to equal(failure) }

      fresh = parent.approve_async(root_id, approval_request_id: request.id, approved: true)
      expect(result_of(fresh)).to include(output: "parent completed")
      expect(effects).to eq(["check"])
      expect(recorder.calls.size).to eq(2)
      expect(parent.unload!).to be(true)
    end
  end
end
