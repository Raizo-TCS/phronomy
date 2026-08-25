# frozen_string_literal: true

require "spec_helper"
require "time"
require "timeout"

class ACS15RecoveryAgent < Phronomy::Agent::Base
  agent_definition id: "acs15-recovery-agent", version: 1
  model "test-model"
  instructions "Return a short answer."
end

RSpec.describe "ACS-15 durable Agent recovery and CG-09 event API" do
  after do
    Phronomy.reset_runtime!
  rescue
    nil
  end

  describe "Agent-incarnation event binding" do
    it "binds on_event at create and returns the same live owner from load without rebinding" do
      persistence = Phronomy::Persistence::InMemory.new
      listener = ->(_event) {}
      agent = ACS15RecoveryAgent.create(
        agent_id: "acs15-live-owner",
        persistence: persistence,
        on_event: listener
      )

      loaded = ACS15RecoveryAgent.load(
        "acs15-live-owner",
        persistence: persistence
      )

      expect(loaded).to equal(agent)
    end

    it "rejects listener rebinding when load resolves an already-live Agent" do
      persistence = Phronomy::Persistence::InMemory.new
      listener = ->(_event) {}
      ACS15RecoveryAgent.create(
        agent_id: "acs15-no-rebind",
        persistence: persistence,
        on_event: listener
      )

      expect {
        ACS15RecoveryAgent.load(
          "acs15-no-rebind",
          persistence: persistence,
          on_event: listener
        )
      }.to raise_error(Phronomy::ConfigurationError, /already live/)
    end

    it "rejects on_event and a construction block together" do
      persistence = Phronomy::Persistence::InMemory.new

      expect {
        ACS15RecoveryAgent.create(
          agent_id: "acs15-double-listener",
          persistence: persistence,
          on_event: ->(_event) {}
        ) { |_event| }
      }.to raise_error(ArgumentError, /either on_event: or a block/)
    end
  end

  describe "clean-break invocation API" do
    it "rejects old per-invocation on_event without starting an execution" do
      agent = ACS15RecoveryAgent.create(
        agent_id: "acs15-old-on-event",
        persistence: Phronomy::Persistence::InMemory.new
      )

      expect {
        agent.invoke_async("hello", on_event: ->(_event) {})
      }.to raise_error(ArgumentError, /removed per-invocation Agent option/)
    end

    it "rejects old per-invocation approval listener" do
      agent = ACS15RecoveryAgent.create(
        agent_id: "acs15-old-approval-listener",
        persistence: Phronomy::Persistence::InMemory.new
      )

      expect {
        agent.invoke_async(
          "hello",
          on_tool_approval_required: ->(_request) {}
        )
      }.to raise_error(ArgumentError, /removed per-invocation Agent option/)
    end

    it "rejects old invocation event-listener blocks" do
      agent = ACS15RecoveryAgent.create(
        agent_id: "acs15-old-block",
        persistence: Phronomy::Persistence::InMemory.new
      )

      expect {
        agent.invoke_async("hello") { |_event| }
      }.to raise_error(ArgumentError, /no longer register Agent events/)
    end

    it "requires an Agent-incarnation listener for stream_async" do
      agent = ACS15RecoveryAgent.create(
        agent_id: "acs15-stream-listener",
        persistence: Phronomy::Persistence::InMemory.new
      )

      expect {
        agent.stream_async("hello")
      }.to raise_error(ArgumentError, /Agent on_event listener/)
    end
  end

  describe Phronomy::Recovery do
    it "normalizes purpose-specific Recovery subjects" do
      expect(
        described_class.normalize_subject(
          type: :llm_call,
          llm_call_id: "call-1"
        )
      ).to eq(type: :llm_call, llm_call_id: "call-1")

      expect(
        described_class.normalize_subject(
          type: :tool_invocation,
          tool_invocation_id: "tool-1"
        )
      ).to eq(type: :tool_invocation, tool_invocation_id: "tool-1")
    end

    it "enforces the resolution material matrix" do
      expect {
        described_class.validate_resolution_material!(
          outcome: :succeeded,
          result_present: true,
          error_present: false
        )
      }.not_to raise_error

      expect {
        described_class.validate_resolution_material!(
          outcome: :failed,
          result_present: false,
          error_present: false
        )
      }.to raise_error(ArgumentError, /requires error/)

      expect {
        described_class.validate_resolution_material!(
          outcome: :not_performed,
          result_present: true,
          error_present: false
        )
      }.to raise_error(ArgumentError, /neither result: nor error:/)
    end

    it "reconciles revisioned Workflow snapshots as post, pre, or conflict" do
      intended = {fields: {count: 2}, phase: "done"}

      expect(
        described_class.compare_revisioned_snapshot(
          record: {revision: 4, snapshot: intended},
          expected_pre_revision: 3,
          intended_snapshot: intended
        )
      ).to eq(:post_state)

      expect(
        described_class.compare_revisioned_snapshot(
          record: {revision: 3, snapshot: {fields: {count: 1}}},
          expected_pre_revision: 3,
          intended_snapshot: intended
        )
      ).to eq(:pre_state)

      expect(
        described_class.compare_revisioned_snapshot(
          record: {revision: 4, snapshot: {fields: {count: 99}}},
          expected_pre_revision: 3,
          intended_snapshot: intended
        )
      ).to eq(:conflict)
    end
  end

  describe Phronomy::Agent::LLMInputManifest do
    let(:manifest_hash) do
      {
        "version" => 1,
        "call_sequence" => 1,
        "call_mode" => "ask",
        "assembly_policy_version" => 1,
        "segments" => [
          {
            "position" => 0,
            "category" => "external_message",
            "role" => "user",
            "content_ref" => "sha256:input",
            "delivery" => "ask_argument",
            "metadata" => {}
          }
        ],
        "model_config_ref" => "sha256:model"
      }
    end

    it "round-trips the exact v1 durable representation" do
      manifest = described_class.from_h(manifest_hash)

      expect(manifest.version).to eq(1)
      expect(manifest.to_h).to eq(manifest_hash)
    end

    it "fails closed for an unsupported manifest version" do
      expect {
        described_class.from_h(manifest_hash.merge("version" => 2))
      }.to raise_error(Phronomy::ConfigurationError, /unsupported LLMInputManifest version/)
    end
  end

  describe "load-integrated Recovery" do
    def install_ambiguous_llm_execution(agent, persistence, execution_id:)
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
            "pending_llm_call_id" => "llm-semantic-1",
            "pending_llm_started_at" => Time.now.utc.iso8601(6),
            "invocation_mode" => "invoke",
            "recovery_contract_version" => 1
          }
        )
        execution = Phronomy::Agent::AgentExecution.from_h(
          execution.to_h.merge(
            "execution_id" => execution_id,
            "status" => "active",
            "phase" => "calling_llm",
            "working_records" => [
              input_record.to_h.merge("execution_id" => execution_id)
            ]
          )
        )
        tx.executions.create_active(execution)
        next_root = root.with(
          agent_revision: root.agent_revision + 1,
          lifecycle_status: :active
        )
        tx.agents.save(
          root.agent_id,
          expected_revision: root.agent_revision,
          root: next_root
        )
        active_execution = execution
      end
      agent.__replace_root(next_root)
      active_execution
    end

    it "publishes recovery_resolution_required with the same logical execution_id after Runtime restart" do
      persistence = Phronomy::Persistence::InMemory.new
      agent = ACS15RecoveryAgent.create(
        agent_id: "acs15-restart",
        persistence: persistence
      )
      execution = install_ambiguous_llm_execution(
        agent,
        persistence,
        execution_id: "execution-stable-1"
      )

      Phronomy.reset_runtime!
      events = Queue.new
      loaded = ACS15RecoveryAgent.load(
        "acs15-restart",
        persistence: persistence,
        on_event: ->(event) { events << event }
      )
      event = Timeout.timeout(2) { events.pop }

      expect(loaded.agent_id).to eq("acs15-restart")
      expect(event.type).to eq(:recovery_resolution_required)
      expect(event.payload[:execution_id]).to eq(execution.execution_id)
      expect(event.payload[:execution_revision]).to eq(execution.execution_revision)
      expect(event.payload[:subject]).to eq(
        type: :llm_call,
        llm_call_id: "llm-semantic-1"
      )
      expect(event.payload[:allowed_outcomes]).to eq(
        %i[succeeded failed not_performed]
      )
    end

    it "fails load and leaves no live owner when Application action is required but no listener is supplied" do
      persistence = Phronomy::Persistence::InMemory.new
      agent = ACS15RecoveryAgent.create(
        agent_id: "acs15-restart-no-listener",
        persistence: persistence
      )
      install_ambiguous_llm_execution(
        agent,
        persistence,
        execution_id: "execution-stable-2"
      )

      Phronomy.reset_runtime!

      expect {
        ACS15RecoveryAgent.load(
          "acs15-restart-no-listener",
          persistence: persistence
        )
      }.to raise_error(Phronomy::ConfigurationError, /load must register on_event/)

      expect(
        ACS15RecoveryAgent.get("acs15-restart-no-listener")
      ).to be_nil
    end
  end
end
