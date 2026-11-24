# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe "Standalone Agent terminal persistence evidence and explicit save-only retry" do
  let(:persistence) { Phronomy::PersistenceComposition.in_memory.agent }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "terminal-persistence-retry", version: 1
    end
  end
  let(:agent) { agent_class.create(agent_id: "terminal-retry-agent", persistence: persistence) }
  let(:worker) { Phronomy::Agent::ExecutionOutcomeCommitter.new(agent: agent, persistence: persistence) }
  let(:schema) do
    {type: "object", properties: {answer: {type: "string"}}, required: ["answer"], additionalProperties: false}
  end
  let(:response) do
    Phronomy::LLMAdapter::Response.new(content: '{"answer":"retained answer"}', finish_reason: :stop)
  end
  let(:execution) do
    input = Phronomy::Agent::JournalRecord.new(agent_id: agent.agent_id,
      execution_id: "terminal-retry-execution", kind: :external_message, channel: :llm,
      role: :user, content_ref: persistence.contents.put_text("original question"),
      context_generation: agent.agent_root.transcript_generation, context_candidate: true)
    metadata = Phronomy::Agent::OutputContract.new(schema).metadata(persistence.contents)
    Phronomy::Agent::AgentExecution.start(agent_root: agent.agent_root, input_record: input,
      execution_id: "terminal-retry-execution", metadata: metadata).with(status: :active, phase: :calling_llm)
  end

  def command(error: nil)
    view = Phronomy::Agent::ExecutionOutcomeCommitter::TerminalView.new(
      phase: :completed, output: response.content, response: response, usage: response.usage,
      approval_request: nil, rejected: false, input_blocked: false, output_blocked: false,
      block_error: nil, invocation_error: nil, handoff: nil, callback_failure: nil,
      source_error: error, cancel_requested: error.is_a?(Phronomy::CancellationError)
    )
    Phronomy::Agent::ExecutionOutcomeCommitter::Command.new(
      execution_id: execution.execution_id, fsm_session_id: "terminal-retry-session",
      expected_execution_revision: execution.execution_revision, root: agent.agent_root,
      journal_records: [].freeze, execution: execution,
      runtime_snapshot: {llm_results: [].freeze, runtime_events: [].freeze, active_call: nil}.freeze,
      terminal_view: view, state_required: true, wiring: {}.freeze
    )
  end

  # Fail only after the entire original proposal and its proof have been made.
  # The in-memory outer transaction then actually removes newly written content.
  def rollback_complete_proposal(operation)
    retained = nil
    armed = true
    allow(persistence.coordinator).to receive(:atomic).and_wrap_original do |original, &write|
      if armed
        armed = false
        original.call do |scope|
          write.call(scope)
          raise IOError, "terminal transaction rolled back after proposal"
        end
      else
        original.call(&write)
      end
    end
    expect { worker.commit_outcome(operation, on_evidence: ->(evidence) { retained = evidence }) }
      .to raise_error(IOError, /rolled back after proposal/)
    expect(retained).not_to be_nil
    retained
  end

  def stored_state
    {
      root: persistence.agents.load(agent.agent_id).to_h,
      execution: persistence.executions.load(execution.execution_id).to_h,
      journal: persistence.journals.read(agent.agent_id, after: 0).map(&:to_h),
      cancelled: persistence.cancellation_requested?(agent_id: agent.agent_id, execution_id: execution.execution_id)
    }
  end

  def expect_no_persistence_writes
    expect_any_instance_of(Phronomy::Persistence::ContentRepository).not_to receive(:put)
    expect_any_instance_of(Phronomy::Agent::Persistence::JournalRepository).not_to receive(:append)
    expect_any_instance_of(Phronomy::Agent::Persistence::ExecutionRepository).not_to receive(:save)
    expect_any_instance_of(Phronomy::Agent::Persistence::AgentRepository).not_to receive(:save)
    expect_any_instance_of(Phronomy::Agent::Persistence::CancellationRepository).not_to receive(:request)
  end

  before do
    persistence.transaction { |records| records.executions.create_active(execution) }
  end

  it "restores rolled-back bytes and exactly the captured outcome without reparsing or reencoding" do
    counts = Hash.new(0)
    parser_trace = TracePoint.new(:call) do |event|
      counts[:parse] += 1 if event.defined_class == Phronomy::OutputParser::JsonSchemaParser && event.method_id == :parse
    end
    parser_trace.enable
    allow(Phronomy::Agent::RuntimeRecordEncoder).to receive(:encode).and_wrap_original do |original, *args, **keywords|
      counts[:encode] += 1
      original.call(*args, **keywords)
    end
    operation = command
    before = stored_state
    evidence = rollback_complete_proposal(operation)
    captured = evidence.outcome
    expect(captured.type).to eq(:completed), captured.error_diagnostic.inspect
    expect(stored_state).to eq(before)
    expect(persistence.contents.exist?(captured.execution.result_ref)).to be false
    missing = evidence.content_writes.reject { |write| persistence.contents.exist?(write.reference) }
    expect(missing).not_to be_empty
    expect(evidence.reconcile(persistence: persistence).disposition).to eq(:not_committed)

    retried = evidence.retry(persistence: persistence)
    expect(retried.disposition).to eq(:committed)
    expect(retried.evidence).to equal(evidence)
    expect(evidence.outcome).to equal(captured)
    expect(persistence.executions.load(execution.execution_id).to_h).to eq(captured.execution.to_h)
    expect(persistence.agents.load(agent.agent_id).to_h).to eq(captured.root.to_h)
    expect(persistence.journals.read(agent.agent_id, after: 0).map(&:to_h)).to eq(captured.appended_records.map(&:to_h))
    evidence.content_writes.each do |write|
      expect(persistence.contents.fetch(write.reference)).to eq(write.bytes)
    end
    expect(captured.result.fetch(:output)).to eq("answer" => "retained answer")
    expect(captured.result.fetch(:messages).map(&:content)).to eq(["original question"])
    expect(counts).to eq(parse: 1, encode: 1)
    expect(agent.agent_root).to equal(operation.root)
    expect(execution.execution_id).to eq(captured.execution.execution_id)
  ensure
    parser_trace&.disable
  end

  [Phronomy::Error, Phronomy::CancellationError].each do |error_class|
    it "preserves the original #{error_class} diagnosis and durable error bytes on save-only retry" do
      original_error = error_class.new("original semantic terminal failure")
      evidence = rollback_complete_proposal(command(error: original_error))
      captured = evidence.outcome
      expect(persistence.contents.exist?(captured.execution.error_ref)).to be false
      expect(evidence.retry(persistence: persistence).disposition).to eq(:committed)
      expect(captured.error_diagnostic).to eq("class" => error_class.name, "message" => original_error.message)
      expect(persistence.executions.load(execution.execution_id).status)
        .to eq((error_class == Phronomy::CancellationError) ? :cancelled : :failed)
      expect(persistence.contents.fetch_json(captured.execution.error_ref))
        .to eq("class" => error_class.name, "message" => original_error.message)
    end
  end

  %i[cancellation root execution journal].each do |conflict|
    it "makes no writes when the captured pre-state has a #{conflict} conflict" do
      evidence = rollback_complete_proposal(command)
      case conflict
      when :cancellation
        persistence.request_cancellation(agent_id: agent.agent_id, execution_id: execution.execution_id)
      when :root
        root = persistence.agents.load(agent.agent_id)
        persistence.agents.save(agent.agent_id, expected_revision: root.agent_revision,
          root: root.with(agent_revision: root.agent_revision + 1, context_revision: root.context_revision + 1))
      when :execution
        current = persistence.executions.load(execution.execution_id)
        persistence.executions.save(execution.execution_id, expected_revision: current.execution_revision,
          execution: current.with(metadata: current.metadata.merge("another_writer" => true)))
      when :journal
        record = execution.working_records.first
        persistence.journals.append(agent.agent_id, expected_position: agent.agent_root.journal_position,
          records: [record])
      end
      changed = stored_state
      expect_no_persistence_writes
      expect(evidence.retry(persistence: persistence).disposition).to eq(:unknown)
      expect(stored_state).to eq(changed)
      expect(persistence.contents.exist?(evidence.outcome.execution.result_ref)).to be false
    end
  end

  it "uses readback after a lost retry reply and performs no second write on repeated retry" do
    evidence = rollback_complete_proposal(command)
    armed = true
    allow(persistence.coordinator).to receive(:atomic).and_wrap_original do |original, &write|
      result = original.call(&write)
      if armed
        armed = false
        raise IOError, "retry committed but reply was lost"
      end
      result
    end
    counts = Hash.new(0)
    {
      journal: [Phronomy::Agent::Persistence::JournalRepository, :append],
      execution: [Phronomy::Agent::Persistence::ExecutionRepository, :save],
      root: [Phronomy::Agent::Persistence::AgentRepository, :save]
    }.each do |label, (repository, method)|
      allow_any_instance_of(repository).to receive(method).and_wrap_original do |original, *args, **keywords|
        counts[label] += 1
        original.call(*args, **keywords)
      end
    end
    expect(evidence.retry(persistence: persistence).disposition).to eq(:committed)
    after = stored_state
    expect(evidence.retry(persistence: persistence).disposition).to eq(:committed)
    expect(stored_state).to eq(after)
    expect(counts).to eq(journal: 1, execution: 1, root: 1)
  end

  it "does not allocate recovery evidence on the default ordinary terminal path" do
    expect(Phronomy::Agent::TerminalPersistenceEvidence).not_to receive(:new)
    result = worker.commit_outcome(command)
    expect(result.type).to eq(:completed)
    expect(result.result.fetch(:output)).to eq("answer" => "retained answer")
  end
end
