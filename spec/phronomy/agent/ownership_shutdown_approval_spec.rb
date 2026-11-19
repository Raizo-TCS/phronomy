# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent ownership shutdown at durable approval" do
  let(:approvals) { Queue.new }
  let(:calls) { [] }
  let(:effects) { [] }
  let(:store) { Phronomy::PersistenceComposition.in_memory.agent }
  let(:protected_tool) do
    observed = effects
    Class.new(Phronomy::Tool::Base) do
      tool_name "approval_read"
      description "Read after explicit approval"
      requires_approval true
      define_method(:execute) do
        observed << "approved"
        "approved"
      end
    end
  end
  let(:agent_class) do
    tool = protected_tool
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "ownership-shutdown-approval", version: 1
      model "offline-model"
      tools tool => nil
    end
  end

  before do
    observed = calls
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |request, cancellation_token:|
        observed << request
        if observed.size == 1
          Phronomy::LLMAdapter::Response.new(tool_calls: [
            Phronomy::Tool::CallRequest.new(id: "pending", name: "approval_read", arguments: {})
          ], finish_reason: :tool_calls)
        else
          Phronomy::LLMAdapter::Response.new(content: "approved answer", finish_reason: :stop)
        end
      end
      define_method(:perform_stream) do |request, cancellation_token:, &listener|
        perform_complete(request, cancellation_token: cancellation_token)
      end
    end.new
    Phronomy.configure { |config| config.llm_adapter = adapter }
  end

  %i[invoke invoke_async stream stream_async].each do |operation|
    it "stops #{operation} at its saved wait and resumes approval after reload" do
      notifications = approvals
      adapter = Phronomy.configuration.llm_adapter
      agent = agent_class.create(agent_id: "waiting", persistence: store,
        on_event: ->(event) { notifications << event.payload.fetch(:request) if event.type == :approval_required })
      task = nil
      waiting = if operation.to_s.end_with?("_async")
        task = agent.public_send(operation, "read")
        nil
      else
        Thread.new do
          agent.public_send(operation, "read")
        rescue => error
          error
        end
      end
      request = approvals.pop(timeout: 3)
      expect(request).not_to be_nil
      expect(store.executions.load(request.execution_id).status).to eq(:suspended)
      expect(effects).to be_empty

      result = Phronomy.reset_runtime!(timeout: 1)

      expect(result.cleanup_complete?).to be(true)
      if waiting
        expect(waiting.join(2)).not_to be_nil
        expect(waiting.value).to be_a(Phronomy::ExecutionRehydrationRequiredError)
      else
        expect { task.wait_result }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
      end
      expect { agent.add_knowledge("obsolete owner") }.to raise_error(Phronomy::RuntimeShutdownError)
      Phronomy.configure { |config| config.llm_adapter = adapter }
      replacement = agent_class.load("waiting", persistence: store,
        on_event: ->(event) { notifications << event.payload.fetch(:request) if event.type == :approval_required })
      restored = approvals.pop(timeout: 3)
      expect(restored.id).to eq(request.id)
      expect(restored.execution_id).to eq(request.execution_id)
      answer = replacement.approve(restored.execution_id, approval_request_id: restored.id)
      expect(answer.fetch(:output)).to eq("approved answer")
      expect(effects).to eq(["approved"])
      expect(calls.size).to eq(2)
      expect(store.executions.load(request.execution_id).status).to eq(:completed)
    ensure
      waiting&.join(2)
    end
  end
end
