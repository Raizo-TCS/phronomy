# frozen_string_literal: true

require "spec_helper"

# These expectations also run on the implementation before private extraction.
RSpec.describe Phronomy::Agent::ContextAssembler do
  let(:persistence) { Phronomy::Persistence.in_memory }
  let(:policy) do
    Class.new(Phronomy::Agent::ContextPolicy) do
      def call(input)
        Phronomy::Agent::ContextPolicies::Default.instance.call(input)
      end
    end.new
  end
  let(:agent_class) do
    bound_policy = policy
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "preparation-contract", version: 1
      model "local-model"
      context_window 10_000
      max_output_tokens 100
      instructions "Base instruction"
      context_policy bound_policy
    end
  end
  let(:agent) { agent_class.new(persistence: persistence) }
  let(:root) { agent.agent_root }
  let(:current_record) { record("current", "Persisted current request") }
  let(:prior_record) { record("prior", "Earlier request", sequence: 10) }
  let(:working_record) { record("working", "Working knowledge", kind: :knowledge, sequence: 20) }
  let(:execution) do
    Phronomy::Agent::AgentExecution.start(
      agent_root: root, input_record: current_record,
      execution_id: "preparation-execution",
      metadata: {"current_input_ref" => current_record.content_ref, "current_input_record_id" => current_record.record_id}
    ).with(
      execution_revision: 0,
      working_records: [current_record, working_record,
        record("stale", "Stale knowledge", kind: :knowledge, generation: root.transcript_generation + 1),
        record("ineligible", "Not a candidate", candidate: false)]
    )
  end
  let(:patch) do
    Phronomy::Agent::LLMInputPatch.new(segment_candidates: [
      {content: {"fact" => "Hook knowledge"}, category: :knowledge, metadata: {"label" => "hook"}},
      {content: "Current hook instruction", category: :instruction}
    ])
  end
  let(:handoff) do
    Phronomy::Agent::HandoffContext.new(
      responsibility: "Continue the task",
      items: [Phronomy::Agent::HandoffContext::Item.new(
        candidate_category: :knowledge, policy_category: :knowledge,
        content: "Transferred knowledge", role: :user,
        provenance: Phronomy::Agent::HandoffContext::Provenance.new(
          origin_agent_id: "source-agent", origin_record_id: "source-record"
        )
      )]
    )
  end
  let(:resolver) do
    Phronomy::Agent::ContextCandidateResolver.new(
      content_loader: ->(ref) { persistence.contents.fetch_text(ref) }
    )
  end
  let(:assembler) do
    described_class.new(
      agent: agent, persistence: persistence, candidate_resolver: resolver,
      journal_records: [prior_record]
    )
  end
  let(:events) { [] }
  let(:policy_inputs) { [] }

  def record(id, content, kind: :external_message, sequence: nil, generation: root.transcript_generation, candidate: true)
    Phronomy::Agent::JournalRecord.new(
      record_id: id, agent_id: root.agent_id, execution_id: "preparation-execution",
      kind: kind, channel: :external, role: :user, sequence: sequence,
      content_ref: persistence.contents.put_text(content),
      context_generation: generation, context_candidate: candidate
    )
  end

  def prepare_initial(**overrides)
    assembler.prepare_initial(
      input: "Input supplied to the instruction callback", agent_root: root,
      execution: execution, patch: patch, config: {phronomy_handoff_context: handoff},
      **overrides
    )
  end

  before do
    # Complete fixture writes before observing the preparation's effects.
    execution
    assembler
    allow(policy).to receive(:call).and_wrap_original do |original, input|
      events << :policy
      policy_inputs << input
      original.call(input)
    end
    allow(resolver).to receive(:resolve).and_wrap_original do |original, **values|
      events << [:records, values[:working_records].map(&:record_id), values[:excluded_record_ids]]
      original.call(**values)
    end
    %i[put_text put_json].each do |operation|
      allow(persistence.contents).to receive(operation).and_wrap_original do |original, value|
        events << [operation, value]
        original.call(value)
      end
    end
  end

  it "builds immutable initial instructions and the persisted current request with its provenance" do
    prepared = prepare_initial
    input = prepared.input
    expect([prepared.call_sequence, prepared.call_mode]).to eq([1, :ask])
    expect(input.instruction.map(&:id)).to eq([
      "instruction:agent:preparation-execution:1",
      "instruction:handoff:preparation-execution:1", "hook:preparation-execution:1:1"
    ])
    expect(input.instruction.map { |item| item.provenance.origin }).to eq([:agent_configuration, :handoff_context, :hook])
    expect(input.instruction.take(2).map(&:required?)).to eq([true, true])
    current = input.conversation.flatten.find { |item| item.kind == :current_input }
    expect(current.id).to eq("current-input:preparation-execution")
    expect(current.content).to eq("Persisted current request")
    expect(current.sequence).to eq(24)
    expect(current.delivery).to eq(:ask_argument)
    expect(current).to be_required
    expect(current.provenance.to_h).to eq(
      origin: :working, content_ref: current_record.content_ref, record_id: "current",
      agent_id: root.agent_id, execution_id: execution.execution_id, llm_call_id: nil
    )
    expect(current.metadata).to eq(
      "source_agent_id" => root.agent_id, "source_execution_id" => execution.execution_id,
      "handoff_policy_category" => "current_request"
    )
    expect([prepared, input, input.instruction, input.conversation, current, current.provenance, current.metadata])
      .to all(be_frozen)
  end

  it "filters working generations, excludes the initial input and preserves record/Hook/Handoff order" do
    prepared = prepare_initial
    expect(events).to eq([
      [:records, %w[current working], ["current"]],
      [:put_json, {"fact" => "Hook knowledge"}],
      [:put_text, "Current hook instruction"],
      [:put_text, "Transferred knowledge"], :policy
    ])
    expect(prepared.input.knowledge.map(&:content))
      .to eq(["Working knowledge", {"fact" => "Hook knowledge"}, "Transferred knowledge"])
    expect(prepared.input.conversation.flatten.map(&:content))
      .to eq(["Earlier request", "Persisted current request"])
  end

  it "omits empty base instructions and an absent Handoff without omitting the current request" do
    allow(agent).to receive(:build_instructions).and_return(nil)
    prepared = prepare_initial(config: {}, patch: Phronomy::Agent::LLMInputPatch.empty)
    expect(prepared.input.instruction).to be_empty
    expect(prepared.input.conversation.flatten.count { |item| item.delivery == :ask_argument }).to eq(1)
    expect(events).to eq([[:records, %w[current working], ["current"]], :policy])
  end

  it "retains base instructions on follow-up and rebuilds current hooks and record candidates" do
    initial = prepare_initial
    manifest, manifest_ref = assembler.finalize(initial)
    call = Phronomy::Agent::LLMCallRecord.new(
      execution_id: execution.execution_id, sequence: 1, status: :completed,
      manifest_ref: manifest_ref, completed_at: "2026-01-01T00:00:00.000000Z"
    )
    next_execution = execution.with(execution_revision: 0, llm_calls: [call])
    next_patch = Phronomy::Agent::LLMInputPatch.new(
      segment_candidates: [{content: "New hook instruction", category: :instruction}]
    )
    events.clear
    prepared = assembler.prepare_followup(
      base_manifest: manifest, agent_root: root, execution: next_execution,
      patch: next_patch, config: {phronomy_handoff_context: handoff}
    )
    expect([prepared.call_sequence, prepared.call_mode]).to eq([2, :complete])
    expect(prepared.input.previous_manifest).to equal(manifest)
    expect(prepared.input.instruction.map(&:content))
      .to eq(["Base instruction", "Continue the task", "New hook instruction"])
    expect(prepared.input.instruction.last.id).to eq("hook:preparation-execution:2:0")
    expect(prepared.input.conversation.flatten.map(&:delivery)).to all(eq(:chat_message))
    expect(prepared.input.conversation.flatten.find { |item| item.provenance.record_id == "current" }).to be_required
    expect(events).to eq([
      [:records, %w[current working], []], [:put_text, "New hook instruction"],
      [:put_text, "Transferred knowledge"], :policy
    ])
  end

  it "invokes Policy once during preparation and keeps finalization inside the caller's transaction" do
    expect(persistence).not_to receive(:transaction)
    prepared = prepare_initial
    expect(policy_inputs).to eq([prepared.input])
    # A separate service over the same backend supplies the commit transaction.
    commit_service = Phronomy::Persistence.new(backend: persistence.backend)
    expect(policy).not_to receive(:call)
    manifest, ref = commit_service.transaction { |tx| assembler.finalize(prepared, persistence: tx) }
    expect(manifest.call_mode).to eq(:ask)
    expect(manifest.assembly_policy_version).to eq(8)
    expect(persistence.contents.fetch_json(ref)).to eq(manifest.to_h)
    expect(manifest.segments.count { |segment| segment.delivery == :ask_argument }).to eq(1)
  end

  it "rejects reserved hook metadata before attempting to read a missing current input" do
    invalid = Phronomy::Agent::LLMInputPatch.new(segment_candidates: [
      {content: "hook", metadata: {"context_policy_origin" => "forged"}}
    ])
    no_input = execution.with(execution_revision: 0, metadata: {})
    expect { prepare_initial(execution: no_input, patch: invalid) }
      .to raise_error(ArgumentError, /Framework-reserved key/)
    expect(events).to be_empty
  end

  it "fails on a missing current-input reference before resolving or storing candidates" do
    no_input = execution.with(execution_revision: 0, metadata: {})
    expect { prepare_initial(execution: no_input) }.to raise_error(KeyError, /current_input_ref/)
    expect(events).to be_empty
  end

  it "propagates the resolver's original exception before Hook or Handoff writes" do
    error = RuntimeError.new("candidate read failed")
    allow(resolver).to receive(:resolve).and_raise(error)
    expect { prepare_initial }.to raise_error { |raised| expect(raised).to equal(error) }
    expect(events).to be_empty
  end

  it "keeps Hook writes before the existing Handoff type error and does not invoke Policy" do
    invalid = Struct.new(:responsibility).new("Responsibility before type validation")
    expect { prepare_initial(config: {phronomy_handoff_context: invalid}) }
      .to raise_error(ArgumentError, "phronomy_handoff_context must be a HandoffContext")
    expect(events).to eq([
      [:records, %w[current working], ["current"]],
      [:put_json, {"fact" => "Hook knowledge"}], [:put_text, "Current hook instruction"]
    ])
  end

  it "propagates the Policy's original exception after candidate content writes" do
    error = RuntimeError.new("application policy failed")
    allow(policy).to receive(:call).and_raise(error)
    expect { prepare_initial }.to raise_error { |raised| expect(raised).to equal(error) }
    expect(events).to eq([
      [:records, %w[current working], ["current"]],
      [:put_json, {"fact" => "Hook knowledge"}], [:put_text, "Current hook instruction"],
      [:put_text, "Transferred knowledge"]
    ])
  end
end
