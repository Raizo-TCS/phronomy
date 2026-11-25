# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::DispatchPersistenceEvidence do
  let(:persistence) { Phronomy::PersistenceComposition.in_memory.agent }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "dispatch-proof", version: 1
      model "local-model"
      max_output_tokens 512
    end
  end
  let(:agent) { agent_class.create(agent_id: "dispatch-proof-owner", persistence: persistence) }
  let(:worker) { Phronomy::Agent::DispatchPreparation.new(agent: agent, persistence: persistence) }
  let(:execution) do
    input = Phronomy::Agent::JournalRecord.new(agent_id: agent.agent_id,
      execution_id: "dispatch-proof-run", kind: :external_message, channel: :llm,
      role: :user, content_ref: persistence.contents.put_text("input"), context_candidate: true)
    Phronomy::Agent::AgentExecution.start(agent_root: agent.agent_root,
      input_record: input, execution_id: "dispatch-proof-run").with(status: :active)
  end
  let(:manifest) do
    Phronomy::Context::LLMInputManifest.new(call_sequence: 1, call_mode: :complete,
      segments: [], model_config_ref: persistence.contents.put_json(
        "model" => "local-model", "context_window" => 4096,
        "max_output_tokens" => 512, "cache_instructions" => false
      ), tool_definitions_ref: persistence.contents.put_json([]),
      adapter_name: Phronomy.configuration.llm_adapter.class.name)
  end
  let(:snapshot) { {llm_results: [], runtime_events: [], active_call: nil}.freeze }

  before { persistence.transaction { |records| records.executions.create_active(execution) } }

  def command(kind)
    common = {execution_id: execution.execution_id, fsm_session_id: "dispatch-proof-session",
              expected_execution_revision: execution.execution_revision, root: agent.agent_root,
              execution: execution, runtime_snapshot: snapshot, invocation_config: {}.freeze}
    if kind == :provider
      Phronomy::Agent::DispatchPreparation::ProviderCommand.new(**common,
        journal_records: [].freeze, base_manifest: manifest, streaming: false,
        pending_llm_call_id: "dispatch-proof-call", pending_llm_started_at: "2026-11-26T00:00:00Z")
    else
      Phronomy::Agent::DispatchPreparation::ToolCommand.new(**common,
        tool_batch_snapshot: [{"tool_invocation_id" => "dispatch-proof-tool",
                               "tool_name" => "lookup", "arguments" => {"query" => "input"},
                               "status" => "authorized"}].freeze)
    end
  end

  def prepare(kind, operation, **callbacks)
    worker.public_send((kind == :provider) ? :prepare_provider : :prepare_tools, operation, **callbacks)
  end

  def fail_barrier(kind, committed:)
    skip = (kind == :provider) ? 2 : 1
    armed = true
    unavailable = false
    allow(persistence.coordinator).to receive(:atomic).and_wrap_original do |original, &body|
      raise IOError, "read unavailable" if unavailable
      if armed && skip.zero?
        armed = false
        if committed
          original.call(&body)
          unavailable = true
          raise IOError, "lost dispatch response"
        else
          original.call do |scope|
            body.call(scope)
            raise IOError, "dispatch rollback"
          end
        end
      else
        skip -= 1 if armed
        original.call(&body)
      end
    end
  end

  [:provider, :tool].each do |kind|
    context "with #{kind} preparation" do
      it "marks barrier entry before performing the change and publishing its evidence" do
        entered = false
        events = []
        allow_any_instance_of(Phronomy::Agent::ExecutionChange).to receive(:perform).and_wrap_original do |original|
          expect(entered).to be(true)
          events << :perform
          original.call
        end
        started = lambda do
          entered = true
          events << :entered
        end
        prepare(kind, command(kind),
          on_barrier_started: started,
          on_evidence: ->(_proof) { events << :evidence },
          on_outcome: ->(_outcome) { events << :outcome })
        expect(events).to eq(%i[entered perform evidence outcome])
      end

      it "does not mark barrier entry when encoding fails before an execution change" do
        entered = false
        operation = command(kind)
        allow(Phronomy::Agent::RuntimeRecordEncoder).to receive(:encode).and_raise(IOError, "encoding failed")
        expect { prepare(kind, operation, on_barrier_started: -> { entered = true }) }
          .to raise_error(IOError, "encoding failed")
        expect(entered).to be(false)
        expect(persistence.executions.load(execution.execution_id).to_h).to eq(execution.to_h)
      end

      it "marks barrier entry even when the attempted change cannot produce complete evidence" do
        entered = false
        proofs = []
        allow_any_instance_of(Phronomy::Agent::ExecutionChange).to receive(:perform).and_raise(IOError, "barrier entry failed")
        expect {
          prepare(kind, command(kind), on_barrier_started: -> { entered = true },
            on_evidence: ->(proof) { proofs << proof })
        }.to raise_error(IOError, "barrier entry failed")
        expect(entered).to be(true)
        expect(proofs).to be_empty
      end

      it "retains immutable complete proof without a live owner or transaction" do
        proof = outcome = nil
        result = prepare(kind, command(kind), on_evidence: ->(value) { proof = value }, on_outcome: ->(value) { outcome = value })
        expect(outcome).to equal(result)
        expect(proof.execution.to_h).to eq(result.execution.to_h)
        expect(proof.kind).to eq(kind)
        expect(proof).to be_frozen
        expect { proof.before.fetch(0).fetch(0)["changed"] = true }.to raise_error(FrozenError)
        expect(proof.instance_variables).not_to include(:@agent, :@store, :@scope, :@participant, :@write)
        expect(proof.reconcile(persistence: persistence).disposition).to eq(:committed)
        recovered = worker.recover_result(proof)
        expect(recovered.execution).to equal(proof.execution)
        expect(recovered.error).to be_nil if kind == :provider
      end

      it "retains complete post evidence when both the commit reply and immediate readback fail" do
        operation = command(kind)
        fail_barrier(kind, committed: true)
        proof = nil
        expect { prepare(kind, operation, on_evidence: ->(value) { proof = value }) }
          .to raise_error(Phronomy::ExecutionRehydrationRequiredError, /outcome is unknown/)
        expect(proof).not_to be_nil
        expect(proof.reconcile(persistence: persistence).read_error).to be_a(IOError)
        allow(persistence.coordinator).to receive(:atomic).and_call_original
        expect(proof.reconcile(persistence: persistence).disposition).to eq(:committed)
        expect(worker.recover_result(proof).execution.to_h).to eq(persistence.executions.load(execution.execution_id).to_h)
      end

      it "retries only the captured execution after complete pre-state proof" do
        operation = command(kind)
        fail_barrier(kind, committed: false)
        proof = nil
        expect { prepare(kind, operation, on_evidence: ->(value) { proof = value }) }
          .to raise_error(IOError, "dispatch rollback")
        allow(persistence.coordinator).to receive(:atomic).and_call_original
        expect(proof.reconcile(persistence: persistence).disposition).to eq(:not_committed)
        expect(agent).not_to receive(:run_before_llm_input_hooks)
        expect_any_instance_of(Phronomy::Agent::ContextPreparation).not_to receive(:prepare_followup)
        expect(Phronomy::Agent::RuntimeRecordEncoder).not_to receive(:encode)
        expect(proof.retry(persistence: persistence).disposition).to eq(:committed)
        expect(proof.retry(persistence: persistence).disposition).to eq(:committed)
        expect(persistence.executions.load(execution.execution_id).to_h).to eq(proof.execution.to_h)
      end

      it "does not replay a conflicting state or a newly recorded cancellation" do
        operation = command(kind)
        fail_barrier(kind, committed: false)
        proof = nil
        expect { prepare(kind, operation, on_evidence: ->(value) { proof = value }) }.to raise_error(IOError)
        allow(persistence.coordinator).to receive(:atomic).and_call_original
        persistence.request_cancellation(agent_id: agent.agent_id, execution_id: execution.execution_id)
        expect(proof.retry(persistence: persistence).disposition).to eq(:unknown)
        expect(persistence.executions.load(execution.execution_id).to_h).to eq(execution.to_h)
      end

      it "rejects another Store and nested caller transactions without I/O or publication" do
        proof = nil
        prepare(kind, command(kind), on_evidence: ->(value) { proof = value })
        other = Phronomy::Agent::Store.new(coordinator: persistence.coordinator, records: Phronomy::Agent::Persistence::Records)
        expect(other).not_to receive(:guard_agents)
        [proof.reconcile(persistence: other), proof.retry(persistence: other)].each do |result|
          expect(result.disposition).to eq(:unknown)
          expect(result.read_error).to be_a(Phronomy::Persistence::StateConflictError)
        end
        persistence.coordinator.atomic do
          [proof.reconcile(persistence: persistence), proof.retry(persistence: persistence)].each do |result|
            expect(result.disposition).to eq(:unknown)
            expect(result.read_error).to be_a(Phronomy::Persistence::TransactionError)
          end
        end
      end

      it "does not accept an orphan journal tail as the captured post-state" do
        proof = nil
        prepare(kind, command(kind), on_evidence: ->(value) { proof = value })
        record = Phronomy::Agent::JournalRecord.new(agent_id: agent.agent_id,
          execution_id: execution.execution_id, kind: :execution_completed, channel: :audit)
        persistence.journals.append(agent.agent_id, expected_position: agent.agent_root.journal_position, records: [record])
        expect(proof.reconcile(persistence: persistence).disposition).to eq(:unknown)
        expect(proof.retry(persistence: persistence).disposition).to eq(:unknown)
      end

      it "does not claim standalone proof for a reserved execution" do
        operation = command(kind)
        reserved = execution.with(execution_revision: execution.execution_revision,
          metadata: execution.metadata.merge("reservation" => {"owner" => "parent"}))
        proofs = []
        prepare(kind, operation.with(execution: reserved), on_evidence: ->(value) { proofs << value })
        expect(proofs).to be_empty
      end

      it "preserves the original rollback if evidence collection also fails" do
        operation = command(kind)
        fail_barrier(kind, committed: false)
        expect { prepare(kind, operation, on_evidence: ->(_value) { raise IOError, "collector unavailable" }) }
          .to raise_error(IOError, "dispatch rollback")
      end
    end
  end

  it "does not mark Provider barrier entry when an application hook fails" do
    entered = false
    operation = command(:provider)
    allow(agent).to receive(:run_before_llm_input_hooks).and_raise(IOError, "hook failed")
    expect { prepare(:provider, operation, on_barrier_started: -> { entered = true }) }
      .to raise_error(IOError, "hook failed")
    expect(entered).to be(false)
    expect(persistence.executions.load(execution.execution_id).to_h).to eq(execution.to_h)
  end

  it "preserves confirmed Provider persistence separately from recovered materialization failure" do
    operation = command(:provider)
    fail_barrier(:provider, committed: true)
    proof = nil
    expect { prepare(:provider, operation, on_evidence: ->(value) { proof = value }) }
      .to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    allow(persistence.coordinator).to receive(:atomic).and_call_original
    expect(proof.reconcile(persistence: persistence).disposition).to eq(:committed)
    allow_any_instance_of(Phronomy::Agent::RuntimeInput).to receive(:materialize).and_raise(IOError, "input unreadable")
    result = worker.recover_result(proof)
    expect(result.execution).to equal(proof.execution)
    expect(result.runtime_projection).to be_nil
    expect(result.error.message).to eq("input unreadable")
    expect(proof.reconcile(persistence: persistence).disposition).to eq(:committed)
  end
end
