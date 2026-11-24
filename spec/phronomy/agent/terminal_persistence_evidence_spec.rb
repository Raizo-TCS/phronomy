# frozen_string_literal: true

require "spec_helper"
require "weakref"

RSpec.describe Phronomy::Agent::TerminalPersistenceEvidence do
  let(:persistence) { Phronomy::PersistenceComposition.in_memory.agent }
  let(:agent_class) { Class.new(Phronomy::Agent::Base) { agent_definition id: "terminal-proof", version: 1 } }
  let(:agent) { agent_class.create(agent_id: "terminal-proof-owner", persistence: persistence) }
  let(:worker) { Phronomy::Agent::ExecutionOutcomeCommitter.new(agent: agent, persistence: persistence) }
  let(:output) { {"answer" => ["captured"]} }
  let(:execution) do
    input = Phronomy::Agent::JournalRecord.new(agent_id: agent.agent_id,
      execution_id: "terminal-proof-run", kind: :external_message, channel: :llm,
      role: :user, content_ref: persistence.contents.put_text("input"), context_candidate: true)
    Phronomy::Agent::AgentExecution.start(agent_root: agent.agent_root,
      input_record: input, execution_id: "terminal-proof-run").with(status: :active)
  end
  let(:view) do
    Phronomy::Agent::ExecutionOutcomeCommitter::TerminalView.new(phase: :completed,
      output: output, usage: Phronomy::LLMAdapter::TokenUsage.new(input: 2),
      approval_request: nil, rejected: false, input_blocked: false, output_blocked: false,
      block_error: nil, invocation_error: nil, handoff: nil, callback_failure: nil,
      source_error: nil, cancel_requested: false)
  end
  let(:command) do
    Phronomy::Agent::ExecutionOutcomeCommitter::Command.new(
      execution_id: execution.execution_id, fsm_session_id: "terminal-proof-session",
      expected_execution_revision: execution.execution_revision,
      root: agent.agent_root, journal_records: [].freeze, execution: execution,
      runtime_snapshot: {llm_results: [], runtime_events: [], active_call: nil}.freeze,
      terminal_view: view, state_required: true, wiring: {}.freeze
    )
  end

  before { persistence.transaction { |tx| tx.executions.create_active(execution) } }

  def capture(operation = command)
    proofs = []
    result = worker.commit_outcome(operation, on_evidence: ->(proof) { proofs << proof })
    expect(proofs.length).to eq(1)
    [proofs.first, result]
  end

  it "copies mutable result values without freezing caller values or retaining a writer scope" do
    evidence, result = capture
    output.fetch("answer") << "later"
    expect(result.result.fetch(:output)).to equal(output)
    expect(evidence.outcome.result.fetch(:output)).to eq("answer" => ["captured"])
    expect(evidence.outcome.result.fetch(:usage)).to be_frozen
    expect(evidence.outcome.result.fetch(:messages)).to all(be_frozen)
    expect { evidence.before.fetch(0).fetch(0)["changed"] = true }.to raise_error(FrozenError)
    expect { evidence.content_writes.first.bytes << "changed" }.to raise_error(FrozenError)
    expect(evidence).to be_frozen
    expect(evidence.instance_variables).not_to include(:@agent, :@store, :@scope, :@write, :@participant)
    expect(evidence.reconcile(persistence: persistence).disposition).to eq(:committed)
  end

  it "retains diagnostic data without retaining a custom business exception's live references" do
    error_type = Class.new(Phronomy::Error) { attr_accessor :live_owner }
    outcome, reference = Thread.new do
      owner = Object.new
      error = error_type.new("custom failure")
      error.live_owner = owner
      evidence = nil
      worker.commit_outcome(command.with(terminal_view: view.with(source_error: error)),
        on_evidence: ->(proof) { evidence = proof })
      [evidence.outcome, WeakRef.new(owner)]
    end.value
    3.times { GC.start }
    expect(reference.weakref_alive?).to be_falsey
    expect(outcome.error_diagnostic.fetch("message")).to eq("custom failure")
    expect(outcome.error_diagnostic).to be_frozen
  end

  it "rejects another Store before any I/O even when it shares the coordinator" do
    evidence, = capture
    other = Phronomy::Agent::Store.new(coordinator: persistence.coordinator,
      records: Phronomy::Agent::Persistence::Records)
    expect(other.coordinator).not_to receive(:atomic)
    [evidence.reconcile(persistence: other), evidence.retry(persistence: other)].each do |result|
      expect(result.disposition).to eq(:unknown)
      expect(result.read_error).to be_a(Phronomy::Persistence::StateConflictError)
      expect(result.evidence).to equal(evidence)
    end
  end

  it "rejects an orphan journal tail beyond the Root's claimed committed position" do
    evidence, = capture
    extra = Phronomy::Agent::JournalRecord.new(agent_id: agent.agent_id,
      execution_id: execution.execution_id, kind: :execution_completed, channel: :audit)
    persistence.journals.append(agent.agent_id, expected_position: evidence.outcome.root.journal_position, records: [extra])
    expect(evidence.reconcile(persistence: persistence).disposition).to eq(:unknown)
    expect_any_instance_of(Phronomy::Persistence::ContentRepository).not_to receive(:put)
    expect(evidence.retry(persistence: persistence).disposition).to eq(:unknown)
  end

  it "does not publish success or perform replay inside a caller's outer transaction" do
    evidence, = capture
    persistence.coordinator.atomic do
      [evidence.reconcile(persistence: persistence), evidence.retry(persistence: persistence)].each do |result|
        expect(result.disposition).to eq(:unknown)
        expect(result.read_error).to be_a(Phronomy::Persistence::TransactionError)
      end
    end
  end

  it "does not claim evidence for a pre-install fallback terminal operation" do
    proofs = []
    worker.commit_outcome(command.with(state_required: false), on_evidence: ->(proof) { proofs << proof })
    expect(proofs).to be_empty
    expect(persistence.executions.load(execution.execution_id)).to be_terminal
  end

  it "does not claim standalone evidence for reservation-owned execution" do
    reserved = execution.with(execution_revision: execution.execution_revision, metadata: {"reservation" => {"owner" => "parent"}})
    proofs = []
    worker.commit_outcome(command.with(execution: reserved), on_evidence: ->(proof) { proofs << proof })
    expect(proofs).to be_empty
  end

  it "propagates collector failure after successful commit without undoing persistence" do
    expect { worker.commit_outcome(command, on_evidence: ->(_proof) { raise IOError, "collector unavailable" }) }
      .to raise_error(IOError, "collector unavailable")
    expect(persistence.executions.load(execution.execution_id)).to be_terminal
  end

  [false, true].each do |logger_fails|
    it "preserves an original save failure when the collector fails, logger_fails=#{logger_fails}" do
      first = true
      allow(persistence.coordinator).to receive(:atomic).and_wrap_original do |original, &body|
        original.call do |scope|
          result = body.call(scope)
          if first
            first = false
            raise IOError, "original rollback"
          end
          result
        end
      end
      logger = double(warn: nil)
      allow(logger).to receive(:warn).and_raise(IOError, "logger unavailable") if logger_fails
      allow(Phronomy::RuntimeSettings.current).to receive(:logger).and_return(logger)
      expect { worker.commit_outcome(command, on_evidence: ->(_proof) { raise IOError, "collector unavailable" }) }
        .to raise_error(IOError, "original rollback")
      expect(logger).to have_received(:warn).with(/collector unavailable/)
      expect(persistence.executions.load(execution.execution_id)).not_to be_terminal
    end
  end
end
