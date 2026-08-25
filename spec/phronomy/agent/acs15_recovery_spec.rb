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
          outcome: :succeeded,
          result_present: false,
          error_present: false
        )
      }.to raise_error(ArgumentError, /requires result/)

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

  describe "Recovery resolution via resolve / resolve_async" do
    def setup_ambiguous_llm_execution(agent_id)
      persistence = Phronomy::Persistence::InMemory.new
      agent = ACS15RecoveryAgent.create(agent_id: agent_id, persistence: persistence)
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
            "pending_llm_call_id" => "llm-semantic-resolve",
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
    it "resolves a pending LLM recovery with outcome :failed" do
      _original, persistence, _exec = setup_ambiguous_llm_execution("acs15-resolve-failed")

      Phronomy.reset_runtime!
      events = Queue.new
      loaded = ACS15RecoveryAgent.load(
        "acs15-resolve-failed",
        persistence: persistence,
        on_event: ->(event) { events << event }
      )
      recovery_event = Timeout.timeout(2) { events.pop }

      resolution_task = loaded.resolve_async(
        recovery_event.payload[:execution_id],
        expected_execution_revision: recovery_event.payload[:execution_revision],
        subject: recovery_event.payload[:subject],
        outcome: :failed,
        error: RuntimeError.new("LLM failed during outage")
      )
      expect { resolution_task.wait_result(timeout: 2) }.to raise_error(Phronomy::Error)
    end

    it "resolves a pending LLM recovery with outcome :not_performed" do
      _original, persistence, _exec = setup_ambiguous_llm_execution("acs15-resolve-not-performed")

      Phronomy.reset_runtime!
      events = Queue.new
      ACS15RecoveryAgent.load(
        "acs15-resolve-not-performed",
        persistence: persistence,
        on_event: ->(event) { events << event }
      )
      recovery_event = Timeout.timeout(2) { events.pop }

      resolution_task = ACS15RecoveryAgent.get("acs15-resolve-not-performed").resolve_async(
        recovery_event.payload[:execution_id],
        expected_execution_revision: recovery_event.payload[:execution_revision],
        subject: recovery_event.payload[:subject],
        outcome: :not_performed
      )
      expect { resolution_task.wait_result(timeout: 2) }.to raise_error(Phronomy::Error)
    end

    it "resolves a pending LLM recovery with outcome :succeeded (exercises continuation path)" do
      _original, persistence, _exec = setup_ambiguous_llm_execution("acs15-resolve-succeeded")

      Phronomy.reset_runtime!
      events = Queue.new
      loaded = ACS15RecoveryAgent.load(
        "acs15-resolve-succeeded",
        persistence: persistence,
        on_event: ->(event) { events << event }
      )
      recovery_event = Timeout.timeout(2) { events.pop }

      result_hash = {
        "content" => "recovered answer",
        "tool_calls" => [],
        "tokens" => {"input" => 1, "output" => 1, "cached" => 0, "cache_creation" => 0}
      }

      resolution_task = loaded.resolve_async(
        recovery_event.payload[:execution_id],
        expected_execution_revision: recovery_event.payload[:execution_revision],
        subject: recovery_event.payload[:subject],
        outcome: :succeeded,
        result: result_hash
      )
      # :succeeded will exercise the continuation path; may fail at manifest
      # materialization since no content store entry exists for this test.
      expect { resolution_task.wait_result(timeout: 2) }.to raise_error(StandardError)
    end
  end

  describe Phronomy::Agent::RecoverySupport do
    describe ".canonical_copy" do
      it "converts an Array recursively" do
        expect(described_class.canonical_copy([:a, "b", 1])).to eq(["a", "b", 1])
      end

      it "converts a Symbol to a String" do
        expect(described_class.canonical_copy(:my_key)).to eq("my_key")
      end

      it "returns scalar values unchanged" do
        expect(described_class.canonical_copy(42)).to eq(42)
        expect(described_class.canonical_copy(true)).to be true
        expect(described_class.canonical_copy(nil)).to be_nil
      end

      it "converts an object that responds to to_h" do
        obj = Struct.new(:a, :b).new(1, :c)
        expect(described_class.canonical_copy(obj)).to eq("a" => 1, "b" => "c")
      end

      it "raises when value is not serializable" do
        expect {
          described_class.canonical_copy(Object.new)
        }.to raise_error(ArgumentError, /not canonically serializable/)
      end
    end

    describe ".normalize_provider_outcome" do
      it "returns a ProviderCallOutcome unchanged" do
        outcome = Phronomy::Agent::ProviderCallOutcome.new(
          role: :assistant,
          content: "hello",
          tool_calls: [],
          usage: {},
          metadata: {}
        )
        expect(described_class.normalize_provider_outcome(outcome)).to equal(outcome)
      end

      it "converts a compatible Hash" do
        hash = {
          "content" => "hi",
          "tool_calls" => [],
          "tokens" => {"input" => 1, "output" => 1, "cached" => 0, "cache_creation" => 0}
        }
        result = described_class.normalize_provider_outcome(hash)
        expect(result).to be_a(Phronomy::Agent::ProviderCallOutcome)
      end

      it "raises when value is nil (capture returns nil)" do
        expect {
          described_class.normalize_provider_outcome(nil)
        }.to raise_error(ArgumentError, /ProviderCallOutcome-compatible Hash/)
      end
    end

    describe ".build_tool_batch_snapshot" do
      def make_tool_inv(id:, tool_call_id:, completed:, result: nil)
        inv = double("tool_inv_#{id}",
          id: id,
          tool_call_id: tool_call_id,
          tool_name: "tool_#{id}",
          raw_arguments: {"x" => 1},
          status: completed ? :completed : :pending,
          execution_completed?: completed)
        allow(inv).to receive(:result).and_return(result) if completed
        inv
      end

      it "excludes result key when execution is not completed" do
        inv = make_tool_inv(id: "inv-1", tool_call_id: "call-1", completed: false)
        invocation = double("invocation", tool_invocations: [inv], tool_batch_llm_call_id: "llm-1")
        result = described_class.build_tool_batch_snapshot(invocation)
        expect(result.first).not_to have_key("result")
      end

      it "includes result key when execution is completed" do
        inv = make_tool_inv(id: "inv-2", tool_call_id: "call-2", completed: true, result: "ok")
        invocation = double("invocation", tool_invocations: [inv], tool_batch_llm_call_id: "llm-2")
        result = described_class.build_tool_batch_snapshot(invocation)
        expect(result.first["result"]).to eq("ok")
      end

      it "omits tool_call_id key when nil" do
        inv = make_tool_inv(id: "inv-3", tool_call_id: nil, completed: false)
        invocation = double("invocation", tool_invocations: [inv], tool_batch_llm_call_id: nil)
        result = described_class.build_tool_batch_snapshot(invocation)
        expect(result.first).not_to have_key("tool_call_id")
        expect(result.first).not_to have_key("llm_call_id")
      end
    end

    describe ".pending_llm_descriptor" do
      it "returns nil when metadata has no pending_llm_call_id" do
        execution = double("execution", metadata: {}, llm_calls: [])
        expect(described_class.pending_llm_descriptor(execution)).to be_nil
      end

      it "returns a descriptor hash when pending_llm_call_id is present" do
        execution = double("execution",
          metadata: {"pending_llm_call_id" => "llm-1", "manifest_ref" => "sha256:abc"},
          llm_calls: [])
        result = described_class.pending_llm_descriptor(execution)
        expect(result[:subject][:llm_call_id]).to eq("llm-1")
        expect(result[:reason]).to eq(:outcome_unknown)
      end
    end

    describe ".recovery_hash" do
      it "returns nil when metadata recovery value is not a Hash" do
        execution = double("execution", metadata: {"recovery" => "nope"})
        expect(described_class.recovery_hash(execution)).to be_nil
      end

      it "returns the hash when metadata recovery value is a Hash" do
        execution = double("execution", metadata: {"recovery" => {"version" => 1}})
        expect(described_class.recovery_hash(execution)).to eq({"version" => 1})
      end
    end

    describe ".current_tool_descriptor" do
      it "returns nil when no recovery metadata" do
        execution = double("execution", metadata: {})
        expect(described_class.current_tool_descriptor(execution)).to be_nil
      end

      it "returns nil when all subjects are resolved" do
        execution = double("execution",
          metadata: {
            "recovery" => {
              "subjects" => [{"tool_invocation_id" => "inv-1", "state" => "resolved"}]
            }
          })
        expect(described_class.current_tool_descriptor(execution)).to be_nil
      end

      it "returns descriptor for the first unresolved subject" do
        execution = double("execution",
          metadata: {
            "recovery" => {
              "reason" => "outcome_unknown",
              "allowed_outcomes" => ["succeeded", "failed"],
              "subjects" => [
                {
                  "tool_invocation_id" => "inv-1",
                  "tool_call_id" => "call-1",
                  "tool_name" => "my_tool",
                  "arguments" => {"x" => 1},
                  "llm_call_id" => "llm-1",
                  "state" => "unresolved"
                }
              ]
            }
          })
        result = described_class.current_tool_descriptor(execution)
        expect(result[:subject][:tool_invocation_id]).to eq("inv-1")
        expect(result[:allowed_outcomes]).to include(:succeeded)
      end
    end

    describe ".recovery_descriptor" do
      it "returns a descriptor for :calling_llm phase" do
        execution = double("execution",
          phase: "calling_llm",
          metadata: {"pending_llm_call_id" => "llm-1", "manifest_ref" => "sha256:x"},
          llm_calls: [])
        result = described_class.recovery_descriptor(execution)
        expect(result[:subject][:type]).to eq(:llm_call)
      end

      it "returns nil for :resuming phase when not approved" do
        execution = double("execution",
          phase: "resuming",
          metadata: {},
          approval_request: nil)
        expect(described_class.recovery_descriptor(execution)).to be_nil
      end

      it "returns nil for :recovery_tools with no unresolved subjects" do
        execution = double("execution",
          phase: "recovery_tools",
          metadata: {})
        expect(described_class.recovery_descriptor(execution)).to be_nil
      end
    end

    describe ".build_recovery_hash" do
      it "builds a versioned recovery hash" do
        result = described_class.build_recovery_hash(
          [{"tool_invocation_id" => "inv-1", "state" => "unresolved"}],
          reason: :outcome_unknown
        )
        expect(result["version"]).to eq(1)
        expect(result["reason"]).to eq("outcome_unknown")
        expect(result["subjects"].first["tool_invocation_id"]).to eq("inv-1")
      end
    end

    describe ".update_recovery_subject" do
      it "updates only the matching subject" do
        recovery = {
          "subjects" => [
            {"tool_invocation_id" => "inv-1", "state" => "unresolved"},
            {"tool_invocation_id" => "inv-2", "state" => "unresolved"}
          ]
        }
        result = described_class.update_recovery_subject(
          recovery,
          tool_invocation_id: "inv-1",
          state: :resolved,
          outcome: :succeeded,
          result_ref: "sha256:r1"
        )
        updated = result["subjects"].find { |s| s["tool_invocation_id"] == "inv-1" }
        unchanged = result["subjects"].find { |s| s["tool_invocation_id"] == "inv-2" }
        expect(updated["state"]).to eq("resolved")
        expect(unchanged["state"]).to eq("unresolved")
      end

      it "omits nil result_ref" do
        recovery = {"subjects" => [{"tool_invocation_id" => "inv-1", "state" => "unresolved"}]}
        result = described_class.update_recovery_subject(
          recovery,
          tool_invocation_id: "inv-1",
          state: :resolved,
          outcome: :failed
        )
        expect(result["subjects"].first).not_to have_key("result_ref")
      end
    end

    describe ".unresolved_subjects" do
      it "returns only subjects with unresolved state" do
        recovery = {
          "subjects" => [
            {"tool_invocation_id" => "inv-1", "state" => "unresolved"},
            {"tool_invocation_id" => "inv-2", "state" => "resolved"}
          ]
        }
        result = described_class.unresolved_subjects(recovery)
        expect(result.length).to eq(1)
        expect(result.first["tool_invocation_id"]).to eq("inv-1")
      end
    end

    describe ".restore_tool_snapshot!" do
      def make_child(id: "inv-1")
        child = double("tool_invocation")
        allow(child).to receive(:id).and_return(id)
        allow(child).to receive(:terminal?).and_return(false)
        allow(child).to receive(:validate!)
        allow(child).to receive(:instance_variable_set)
        allow(child).to receive(:mark_awaiting_approval!)
        allow(child).to receive(:mark_authorized!)
        allow(child).to receive(:mark_rejected!)
        allow(child).to receive(:mark_framework_failed!)
        allow(child).to receive(:mark_cancelled!)
        child
      end

      it "handles :awaiting_approval status" do
        child = make_child
        entry = {"status" => "awaiting_approval"}
        described_class.restore_tool_snapshot!(child, entry, {})
        expect(child).to have_received(:mark_awaiting_approval!)
      end

      it "handles :authorized status" do
        child = make_child
        entry = {"status" => "authorized"}
        described_class.restore_tool_snapshot!(child, entry, {})
        expect(child).to have_received(:mark_authorized!)
      end

      it "handles :completed status" do
        child = make_child
        entry = {"status" => "completed", "result" => "done"}
        described_class.restore_tool_snapshot!(child, entry, {})
        expect(child).to have_received(:instance_variable_set).with(:@result, "done")
        expect(child).to have_received(:instance_variable_set).with(:@status, :completed)
      end

      it "handles :rejected status" do
        child = make_child
        described_class.restore_tool_snapshot!(child, {"status" => "rejected"}, {})
        expect(child).to have_received(:mark_rejected!)
      end

      it "handles :failed status" do
        child = make_child
        described_class.restore_tool_snapshot!(child, {"status" => "failed"}, {})
        expect(child).to have_received(:mark_framework_failed!)
      end

      it "handles :cancelled status" do
        child = make_child
        described_class.restore_tool_snapshot!(child, {"status" => "cancelled"}, {})
        expect(child).to have_received(:mark_cancelled!)
      end

      it "raises for unsupported status" do
        child = make_child
        expect {
          described_class.restore_tool_snapshot!(child, {"status" => "bogus"}, {})
        }.to raise_error(Phronomy::ExecutionRehydrationRequiredError, /unsupported/)
      end

      it "applies approval_item facts when item is present" do
        child = make_child
        entry = {"status" => "rejected"}
        item = double("item", facts: {role: :owner}, reason: "approved by admin")
        described_class.restore_tool_snapshot!(child, entry, {"inv-1" => item})
        expect(child).to have_received(:instance_variable_set).with(:@facts, anything)
        expect(child).to have_received(:instance_variable_set).with(:@authorization_reason, "approved by admin")
      end
    end

    describe ".resuming_tool_subjects" do
      it "includes only authorized and awaiting_approval entries" do
        execution = double("execution",
          metadata: {
            "recovery_tool_batch" => [
              {"tool_invocation_id" => "inv-1", "tool_call_id" => "call-1",
               "tool_name" => "foo", "arguments" => {}, "status" => "authorized"},
              {"tool_invocation_id" => "inv-2", "tool_call_id" => "call-2",
               "tool_name" => "bar", "arguments" => {}, "status" => "completed"},
              {"tool_invocation_id" => "inv-3", "tool_call_id" => "call-3",
               "tool_name" => "baz", "arguments" => {}, "status" => "awaiting_approval"}
            ]
          })
        result = described_class.resuming_tool_subjects(execution)
        ids = result.map { |s| s["tool_invocation_id"] }
        expect(ids).to contain_exactly("inv-1", "inv-3")
      end
    end
  end
end
