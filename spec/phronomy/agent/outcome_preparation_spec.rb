# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::OutcomePreparation do
  let(:persistence) { Phronomy::PersistenceComposition.in_memory.agent }
  let(:agent_class) { Class.new(Phronomy::Agent::Base) { agent_definition id: "prepared-transcript", version: 1 } }
  let(:agent) { agent_class.create(agent_id: "prepared-transcript-owner", persistence: persistence) }
  let(:output) { +"captured report" }
  let(:usage) { Phronomy::LLMAdapter::TokenUsage.new(input: 3, output: 2) }
  let(:history_ref) { persistence.contents.put_text("historical request") }
  let(:history_record) do
    Phronomy::Agent::JournalRecord.new(agent_id: agent.agent_id, execution_id: "prepared-transcript-run",
      kind: :external_message, channel: :llm, role: :user, content_ref: history_ref,
      context_candidate: true).with_sequence(1)
  end
  let(:buffer) do
    Phronomy::Agent::OutcomeWritePlan::Contents.new(persistence.contents,
      write_class: Phronomy::Agent::TerminalPersistenceEvidence::ContentWrite)
  end
  let(:assistant_ref) { buffer.put_json("role" => "assistant", "content" => "assistant report") }
  let(:assistant_record) do
    Phronomy::Agent::JournalRecord.new(agent_id: agent.agent_id, execution_id: "prepared-transcript-run",
      kind: :assistant_message, channel: :llm, role: :assistant, content_ref: assistant_ref,
      context_candidate: true).with_sequence(2)
  end
  let(:journal_records) { [history_record, assistant_record] }
  let(:current) do
    Phronomy::Agent::AgentExecution.start(agent_root: agent.agent_root,
      input_record: history_record, execution_id: "prepared-transcript-run").with(status: :active)
  end
  let(:execution) { current.with(status: :completed, result_ref: buffer.put_text("captured report"), working_records: []) }
  let(:root) { agent.agent_root.with(agent_revision: agent.agent_root.agent_revision + 1, journal_position: 2) }
  let(:outcome) do
    Phronomy::Agent::ExecutionOutcomeCommitter::Outcome.new(type: :completed,
      execution: execution, root: root, appended_records: journal_records.dup.freeze,
      result: {output: output, usage: usage}.freeze, error: nil, approval_request: nil)
  end
  let(:values) do
    before = [[agent.agent_root.to_h, current.to_h, [], nil, false], nil]
    plan = Phronomy::Agent::OutcomeWritePlan.new(outcome: outcome, writes: buffer.writes)
    {before: before, after: plan.after(before: before, state_data: nil, participation: nil), result: outcome}
  end
  let(:preparation) do
    captured = values
    described_class.new(captured, buffer.writes, journal_records: journal_records,
      persistence: persistence, participant: nil)
  end

  it "retains exact staged values without reading history or publishing an incomplete semantic input" do
    captured = values
    expect(persistence.contents).not_to receive(:fetch)
    expect(persistence.contents).not_to receive(:put)
    capsule = described_class.new(captured, buffer.writes, journal_records: journal_records,
      persistence: persistence, participant: nil)
    expect(capsule).to be_frozen
    expect(capsule).not_to respond_to(:values)
    expect(capsule.instance_variables).not_to include(:@agent, :@store, :@scope, :@write, :@contents, :@thread)
    expect(outcome.result).not_to have_key(:messages)
  end

  it "combines historical reads and unwritten captured content into the complete ordinary result" do
    capsule = preparation
    journal_records.clear
    expect(persistence.contents).to receive(:fetch).with(history_ref).once.and_call_original
    expect(persistence.contents).not_to receive(:fetch).with(assistant_ref)
    expect(persistence.contents).not_to receive(:put)
    input = capsule.materialize(persistence: persistence)
    semantic = input.values.fetch(:result)
    expect(semantic.result.fetch(:output)).to equal(output)
    expect(semantic.result.fetch(:usage)).to equal(usage)
    expect(semantic.result.fetch(:messages).map { |message| [message.role, message.content] })
      .to eq([[:user, "historical request"], [:assistant, "assistant report"]])
    expect(semantic.result.fetch(:messages)).to be_frozen
    expect(semantic.result).to be_frozen
    expect(semantic.root).to equal(root)
    expect(persistence.contents.exist?(assistant_ref)).to be(false)
    proof = input.materialize(persistence: persistence)
    expect(proof.outcome.execution_observation.result).to eq("captured report")
  end

  it "retries only immutable-content materialization after a transient historical read failure" do
    capsule = preparation
    calls = 0
    allow(persistence.contents).to receive(:fetch).with(history_ref).and_wrap_original do |original, reference|
      calls += 1
      raise IOError, "historical content temporarily unavailable" if calls == 1
      original.call(reference)
    end
    expect(persistence.contents).not_to receive(:put)
    expect { capsule.materialize(persistence: persistence) }.to raise_error(IOError)
    input = capsule.materialize(persistence: persistence)
    expect(input.values.fetch(:result).result.fetch(:messages).length).to eq(2)
    expect(capsule.materialize(persistence: persistence)).to equal(input)
    expect(calls).to eq(2)
  end

  it "does not copy application output when constructing the complete input or detached proof" do
    copies = 0
    original = Class.new(String) do
      define_method(:initialize_copy) do |source|
        copies += 1
        super(source)
        raise IOError, "custom output copy unavailable"
      end
    end.new("captured report")
    captured = values.merge(result: outcome.with(result: outcome.result.merge(output: original).freeze))
    capsule = described_class.new(captured, buffer.writes, journal_records: journal_records,
      persistence: persistence, participant: nil)
    expect(persistence.contents).to receive(:fetch).with(history_ref).once.and_call_original
    input = capsule.materialize(persistence: persistence)
    expect(input.values.fetch(:result).result.fetch(:output)).to equal(original)
    expect(input.values.fetch(:result).result.fetch(:messages).length).to eq(2)
    2.times do
      expect(capsule.materialize(persistence: persistence)).to equal(input)
      expect(input.materialize(persistence: persistence).outcome.execution_observation.result).to eq("captured report")
    end
    expect(copies).to eq(0)
  end

  it "keeps an unrelated complete input construction failure single-use" do
    capsule = preparation
    failure = IOError.new("complete input unavailable")
    expect(persistence.contents).to receive(:fetch).with(history_ref).once.and_call_original
    expect(Phronomy::Agent::TerminalPersistenceEvidence::CapturedInput).to receive(:new).once.and_raise(failure)
    3.times do
      expect { capsule.materialize(persistence: persistence) }.to raise_error { |error| expect(error).to equal(failure) }
    end
  end

  it "reuses the same complete input without rereading history after proof construction fails" do
    capsule = preparation
    expect(persistence.contents).to receive(:fetch).with(history_ref).once.and_call_original
    input = capsule.materialize(persistence: persistence)
    attempts = 0
    allow(Phronomy::Agent::TerminalPersistenceEvidence).to receive(:capture_values).and_wrap_original do |original, *args, **options|
      attempts += 1
      raise IOError, "detached proof temporarily unavailable" if attempts == 1
      original.call(*args, **options)
    end
    expect { input.materialize(persistence: persistence) }.to raise_error(IOError)
    expect(capsule.materialize(persistence: persistence)).to equal(input)
    expect(input.values.fetch(:result).result.fetch(:messages).length).to eq(2)
    expect(input.materialize(persistence: persistence).outcome.execution_observation.result).to eq("captured report")
    expect(attempts).to eq(2)
  end

  it "rejects another Store before any content read, including after a complete input is cached" do
    capsule = preparation
    other = Phronomy::Agent::Store.new(coordinator: persistence.coordinator, records: Phronomy::Agent::Persistence::Records)
    expect(other).not_to receive(:contents)
    expect { capsule.materialize(persistence: other) }.to raise_error(Phronomy::Persistence::StateConflictError)
    capsule.materialize(persistence: persistence)
    expect { capsule.materialize(persistence: other) }.to raise_error(Phronomy::Persistence::StateConflictError)
  end

  it "keeps a missing historical reference unavailable without writing or inventing a transcript" do
    capsule = preparation
    allow(persistence.contents).to receive(:fetch).with(history_ref).and_raise(Phronomy::Persistence::NotFoundError, "missing immutable content")
    expect(persistence.contents).not_to receive(:put)
    2.times do
      expect { capsule.materialize(persistence: persistence) }.to raise_error(Phronomy::Persistence::NotFoundError)
    end
  end

  it "rejects corrupt historical bytes before caching an input" do
    capsule = preparation
    allow(persistence.contents).to receive(:fetch).with(history_ref).and_return("unrelated bytes")
    expect { capsule.materialize(persistence: persistence) }.to raise_error(Phronomy::ContentStore::IntegrityError, /digest mismatch/)
    allow(persistence.contents).to receive(:fetch).with(history_ref).and_call_original
    expect(capsule.materialize(persistence: persistence).values.fetch(:result).result.fetch(:messages).first.content)
      .to eq("historical request")
  end

  it "does not call an application output conversion while reconstructing presentation data" do
    capsule = preparation
    output.replace("changed live output")
    expect(output).not_to receive(:to_s)
    input = capsule.materialize(persistence: persistence)
    expect(input.values.fetch(:result).result.fetch(:output)).to equal(output)
    expect(input.materialize(persistence: persistence).outcome.execution_observation.result).to eq("captured report")
  end

  it "does not materialize a transcript for a captured outcome without presentation records" do
    waiting = outcome.with(type: :coordination_wait, execution: current, root: agent.agent_root,
      appended_records: [].freeze, result: nil)
    before = values.fetch(:before)
    captured = {before: before, after: before, result: waiting}
    capsule = described_class.new(captured, [], journal_records: nil,
      persistence: persistence, participant: nil)
    expect(persistence.contents).not_to receive(:fetch)
    expect(Phronomy::Agent::RuntimeInput).not_to receive(:new)
    expect(capsule.materialize(persistence: persistence).values.fetch(:result)).to equal(waiting)
  end

  it "does not treat a successful outcome without transcript inputs as complete" do
    captured = values
    expect { described_class.new(captured, buffer.writes, journal_records: nil, persistence: persistence, participant: nil) }
      .to raise_error(ArgumentError, /requires captured transcript records/)
  end
end
