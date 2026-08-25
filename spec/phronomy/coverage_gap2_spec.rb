# frozen_string_literal: true

require "spec_helper"

# Targeted branch-coverage fill-in for medium-complexity utility classes.

RSpec.describe "Coverage gap fill-in (round 2)" do
  describe "Phronomy::Agent::ToolDefinitionSet.normalize" do
    it "converts an Array recursively" do
      expect(Phronomy::Agent::ToolDefinitionSet.normalize([:a, "b"])).to eq(["a", "b"])
    end

    it "converts a Symbol to a String" do
      expect(Phronomy::Agent::ToolDefinitionSet.normalize(:my_key)).to eq("my_key")
    end

    it "delegates to to_json_schema when available" do
      obj = Class.new { def to_json_schema = {type: "string"} }.new
      expect(Phronomy::Agent::ToolDefinitionSet.normalize(obj)).to eq({"type" => "string"})
    end

    it "delegates to to_h when to_json_schema is absent" do
      obj = Struct.new(:x).new(1)
      expect(Phronomy::Agent::ToolDefinitionSet.normalize(obj)).to eq({"x" => 1})
    end

    it "raises for values that cannot be serialized" do
      # Object.new has neither to_json_schema nor to_h
      expect {
        Phronomy::Agent::ToolDefinitionSet.normalize(Object.new)
      }.to raise_error(ArgumentError, /unsupported tool definition/)
    end
  end

  describe "Phronomy::MultiAgent::AdmissionRegistry" do
    let(:registry) { Phronomy::MultiAgent::AdmissionRegistry.new }

    it "raises HandoffError when same coordinator is admitted twice" do
      coordinator = Object.new
      registry.admit!(coordinator)
      expect {
        registry.admit!(coordinator)
      }.to raise_error(Phronomy::HandoffError, /already active/)
    end

    it "returns false-ish when releasing an unknown coordinator" do
      unknown = Object.new
      result = registry.release!(unknown)
      expect(result).to be_falsy
    end

    it "returns false from wait_until_idle when deadline has already passed" do
      coordinator = Object.new
      registry.admit!(coordinator)
      # Use an already-expired deadline
      past = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1.0
      result = registry.wait_until_idle(past)
      expect(result).to be false
      registry.release!(coordinator)
    end
  end

  describe "Phronomy::GeneratorVerifier::PipelineState#handle_fsm_event" do
    let(:pipeline_state_class) { Phronomy::GeneratorVerifier.send(:const_get, :PipelineState) }
    let(:state) do
      s = pipeline_state_class.new(
        draft_request_id: "req-draft",
        review_request_id: "req-review"
      )
      s.set_graph_metadata(workflow_instance_id: "wf-1")
      s
    end

    def make_event(type, payload)
      double("FSMEvent", type: type, payload: payload)
    end

    it "returns :consume when draft_completed has mismatched request_id" do
      event = make_event(:draft_completed, {request_id: "other-id", draft: "x", self_score: 1.0, citations: []})
      expect(state.handle_fsm_event(event)).to eq(:consume)
    end

    it "returns :consume when review_completed has mismatched request_id" do
      event = make_event(:review_completed, {request_id: "other-id", review_score: 0.9, approved: true, feedback: ""})
      expect(state.handle_fsm_event(event)).to eq(:consume)
    end

    it "returns :consume when draft_failed has mismatched request_id" do
      event = make_event(:draft_failed, {request_id: "other-id", error: RuntimeError.new})
      expect(state.handle_fsm_event(event)).to eq(:consume)
    end

    it "returns :consume when review_failed has mismatched request_id" do
      event = make_event(:review_failed, {request_id: "other-id", error: RuntimeError.new})
      expect(state.handle_fsm_event(event)).to eq(:consume)
    end

    it "returns false for unknown event types" do
      event = make_event(:unknown_event, {})
      expect(state.handle_fsm_event(event)).to be false
    end
  end

  describe "Recovery resolution error paths" do
    class ACS15RecoveryAgentForErrors < Phronomy::Agent::Base
      agent_definition id: "acs15-recovery-error-agent", version: 1
      model "test-model"
      instructions "Return a short answer."
    end

    after {
      begin
        Phronomy.reset_runtime!
      rescue
        nil
      end
    }

    def install_calling_llm_execution(agent_id)
      persistence = Phronomy::Persistence::InMemory.new
      agent = ACS15RecoveryAgentForErrors.create(agent_id: agent_id, persistence: persistence)
      root = agent.agent_root
      active_execution = nil
      next_root = nil

      persistence.transaction do |tx|
        input_ref = tx.contents.put_text("recover me")
        input_record = Phronomy::Agent::JournalRecord.new(
          agent_id: agent.agent_id,
          kind: :input_received,
          channel: :external,
          role: :user,
          content_ref: input_ref,
          context_generation: root.transcript_generation,
          context_candidate: false
        )
        execution = Phronomy::Agent::AgentExecution.start(
          agent_root: root,
          input_record: input_record,
          metadata: {
            "pending_llm_call_id" => "llm-error-1",
            "pending_llm_started_at" => Time.now.utc.iso8601(6),
            "invocation_mode" => "invoke",
            "recovery_contract_version" => 1
          }
        )
        execution = Phronomy::Agent::AgentExecution.from_h(
          execution.to_h.merge(
            "execution_id" => "#{agent_id}-exec",
            "status" => "active",
            "phase" => "calling_llm",
            "working_records" => [
              input_record.to_h.merge("execution_id" => "#{agent_id}-exec")
            ]
          )
        )
        tx.executions.create_active(execution)
        next_root = root.with(
          agent_revision: root.agent_revision + 1,
          lifecycle_status: :active
        )
        tx.agents.save(root.agent_id, expected_revision: root.agent_revision, root: next_root)
        active_execution = execution
      end
      agent.__replace_root(next_root)
      [agent, persistence, active_execution]
    end

    it "rejects resolve when expected_execution_revision does not match" do
      _orig, persistence, _ = install_calling_llm_execution("acs15-err-rev")

      Phronomy.reset_runtime!
      events = Queue.new
      loaded = ACS15RecoveryAgentForErrors.load(
        "acs15-err-rev",
        persistence: persistence,
        on_event: ->(e) { events << e }
      )
      recovery_event = Timeout.timeout(2) { events.pop }

      task = loaded.resolve_async(
        recovery_event.payload[:execution_id],
        expected_execution_revision: recovery_event.payload[:execution_revision] + 99,
        subject: recovery_event.payload[:subject],
        outcome: :not_performed
      )
      expect { task.wait_result(timeout: 2) }.to raise_error(StandardError)
    end

    it "rejects resolve when outcome is invalid (validated in task)" do
      _orig, persistence, _exec = install_calling_llm_execution("acs15-err-outcome")

      Phronomy.reset_runtime!
      events = Queue.new
      loaded = ACS15RecoveryAgentForErrors.load(
        "acs15-err-outcome",
        persistence: persistence,
        on_event: ->(e) { events << e }
      )
      Timeout.timeout(2) { events.pop }

      task = loaded.resolve_async(
        "#{loaded.agent_id}-exec",
        expected_execution_revision: 0,
        subject: {type: :llm_call, llm_call_id: "llm-error-1"},
        outcome: :invalid_outcome
      )
      expect { task.wait_result(timeout: 2) }.to raise_error(StandardError)
    end
  end

  describe "Workflow legacy config rejection" do
    class WorkflowCoverageContext
      include Phronomy::WorkflowContext

      field :value, type: :replace, default: 0
    end

    after {
      begin
        Phronomy.reset_runtime!
      rescue
        nil
      end
    }

    let(:workflow) do
      Phronomy::Workflow.define(WorkflowCoverageContext) do
        initial :start
        state :start
        state :done
        transition from: :start, on: :finish, to: :done
        transition from: :done, to: :__finish__
      end
    end

    it "raises when :thread_id key is present in config" do
      task = workflow.invoke_async({value: 0}, config: {thread_id: "old-thread-id"})
      expect { task.wait_result(timeout: 1) }.to raise_error(ArgumentError, /thread_id/)
    end
  end
end
