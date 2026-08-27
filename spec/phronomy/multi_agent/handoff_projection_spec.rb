# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::MultiAgent::HandoffProjection do
  def build_agent(definition_id, persistence: Phronomy::Persistence::InMemory.new)
    klass = Class.new(Phronomy::Agent::Base) do
      agent_definition id: definition_id, version: 1
      model "stub-model"
    end
    klass.new(persistence: persistence)
  end

  def policy
    Phronomy::MultiAgent::HandoffPolicy.define do
      required :current_request
      selectable :history, default: :include
      selectable :knowledge, default: :exclude
      selectable :tool_exchanges, default: :include
    end
  end

  def request(handoff, responsibility: "Continue", selection_intent: {})
    Phronomy::MultiAgent::HandoffRequest.new(
      handoff: handoff,
      responsibility: responsibility,
      selection_intent: selection_intent
    )
  end

  def manifest(persistence, segments)
    Phronomy::Agent::LLMInputManifest.new(
      call_sequence: 1,
      call_mode: :complete,
      segments: segments,
      model_config_ref: persistence.contents.put_json({}),
      assembly_policy_version: 7
    )
  end

  def segment(position:, category:, content_ref:, role: :user, tool_call_id: nil, metadata: {})
    Phronomy::Agent::LLMInputManifest::Segment.new(
      position: position,
      category: category,
      role: role,
      content_ref: content_ref,
      delivery: :chat_message,
      tool_call_id: tool_call_id,
      metadata: metadata
    )
  end

  it "materializes selected Context across different Persistence adapters without adopting it into Target Journal" do
    source_persistence = Phronomy::Persistence::InMemory.new
    target_persistence = Phronomy::Persistence::InMemory.new
    source = build_agent("projection-source", persistence: source_persistence)
    target = build_agent("projection-target", persistence: target_persistence)
    handoff = Phronomy::MultiAgent::Handoff.new(
      source_agent: source,
      target_agent: target,
      policy: policy
    )

    content_ref = source_persistence.contents.put_text("knowledge-from-source")
    source_manifest = manifest(source_persistence, [
      segment(
        position: 0,
        category: :knowledge,
        content_ref: content_ref,
        metadata: {
          "handoff_policy_category" => "knowledge",
          "source_agent_id" => source.agent_id,
          "journal_record_id" => "record-a",
          "source_execution_id" => "exec-a",
          "llm_call_id" => "llm-a"
        }
      )
    ])
    target_journal_position = target.agent_root.journal_position

    context = described_class.new.build(
      request: request(handoff, selection_intent: {knowledge: true}),
      manifest: source_manifest,
      persistence: source_persistence,
      source_agent: source
    )

    expect(source.persistence).not_to equal(target.persistence)
    expect(context.items.length).to eq(1)
    item = context.items.first
    expect(item.candidate_category).to eq(:knowledge)
    expect(item.policy_category).to eq(:knowledge)
    expect(item.content).to eq("knowledge-from-source")
    expect(item.provenance.origin_agent_id).to eq(source.agent_id)
    expect(item.provenance.origin_record_id).to eq("record-a")
    expect(item.provenance.transfer_path).to eq([source.agent_id, target.agent_id])
    expect(target.agent_root.journal_position).to eq(target_journal_position)
  end

  it "cannot transfer a forbidden category through Source selection intent" do
    source = build_agent("projection-forbidden-source")
    target = build_agent("projection-forbidden-target")
    forbidden_policy = Phronomy::MultiAgent::HandoffPolicy.define do
      required :current_request
      selectable :history, default: :include
      forbidden :knowledge
      selectable :tool_exchanges, default: :include
    end
    handoff = Phronomy::MultiAgent::Handoff.new(
      source_agent: source,
      target_agent: target,
      policy: forbidden_policy
    )

    expect do
      request(handoff, selection_intent: {knowledge: true})
    end.to raise_error(ArgumentError, /non-selectable categories/)
  end

  it "always transfers a required category even though it is not Source-selectable" do
    source = build_agent("projection-required-source")
    target = build_agent("projection-required-target")
    handoff = Phronomy::MultiAgent::Handoff.new(
      source_agent: source,
      target_agent: target,
      policy: policy
    )
    content_ref = source.persistence.contents.put_text("original-current-request")
    source_manifest = manifest(source.persistence, [
      segment(
        position: 0,
        category: :external_message,
        content_ref: content_ref,
        metadata: {
          "handoff_policy_category" => "current_request",
          "source_agent_id" => source.agent_id,
          "journal_record_id" => "input-a"
        }
      )
    ])

    context = described_class.new.build(
      request: request(handoff),
      manifest: source_manifest,
      persistence: source.persistence,
      source_agent: source
    )

    expect(context.items.map(&:content)).to eq(["original-current-request"])
    expect(context.items.first.policy_category).to eq(:current_request)
  end

  it "preserves multi-hop origin and appends the transfer path A to B to C" do
    a = build_agent("projection-a")
    b = build_agent("projection-b")
    c = build_agent("projection-c")
    a_to_b = Phronomy::MultiAgent::Handoff.new(source_agent: a, target_agent: b, policy: policy)
    b_to_c = Phronomy::MultiAgent::Handoff.new(source_agent: b, target_agent: c, policy: policy)

    a_ref = a.persistence.contents.put_text("knowledge-from-a")
    first_manifest = manifest(a.persistence, [
      segment(
        position: 0,
        category: :knowledge,
        content_ref: a_ref,
        metadata: {
          "handoff_policy_category" => "knowledge",
          "source_agent_id" => a.agent_id,
          "journal_record_id" => "a-record",
          "source_execution_id" => "a-exec",
          "llm_call_id" => "a-llm"
        }
      )
    ])
    first = described_class.new.build(
      request: request(a_to_b, selection_intent: {knowledge: true}),
      manifest: first_manifest,
      persistence: a.persistence,
      source_agent: a
    ).items.fetch(0)

    b_ref = b.persistence.contents.put_text(first.content)
    second_manifest = manifest(b.persistence, [
      segment(
        position: 0,
        category: first.candidate_category,
        content_ref: b_ref,
        metadata: {
          "handoff_policy_category" => first.policy_category.to_s,
          "handoff_provenance" => first.provenance.to_h
        }
      )
    ])
    second = described_class.new.build(
      request: request(b_to_c, selection_intent: {knowledge: true}),
      manifest: second_manifest,
      persistence: b.persistence,
      source_agent: b
    ).items.fetch(0)

    expect(second.candidate_category).to eq(:knowledge)
    expect(second.provenance.origin_agent_id).to eq(a.agent_id)
    expect(second.provenance.origin_record_id).to eq("a-record")
    expect(second.provenance.origin_execution_id).to eq("a-exec")
    expect(second.provenance.origin_llm_call_id).to eq("a-llm")
    expect(second.provenance.transfer_path).to eq([a.agent_id, b.agent_id, c.agent_id])
  end

  it "injects inbound Handoff Context as selectable Target candidates before Context Policy" do
    target = build_agent("projection-target-policy")
    provenance = Phronomy::MultiAgent::HandoffContext::Provenance.new(
      origin_agent_id: "source-agent",
      origin_record_id: "source-record",
      origin_execution_id: "source-execution",
      origin_llm_call_id: nil,
      origin_tool_call_id: nil,
      transfer_path: ["source-agent", target.agent_id]
    )
    item = Phronomy::MultiAgent::HandoffContext::Item.new(
      candidate_category: :knowledge,
      policy_category: :knowledge,
      role: :user,
      content: "transferred-knowledge",
      content_format: :text,
      tool_call_id: nil,
      provenance: provenance,
      metadata: {}
    )
    context = Phronomy::MultiAgent::HandoffContext.new(
      responsibility: "Continue",
      items: [item]
    )
    execution = Struct.new(:execution_id).new("target-execution")
    assembler = Phronomy::Agent::ContextAssembler.new(
      agent: target,
      persistence: target.persistence
    )

    candidates = assembler.send(
      :merge_handoff_candidates,
      [],
      context,
      execution: execution
    )

    expect(candidates.length).to eq(1)
    candidate = candidates.first
    expect(candidate.source_kind).to eq(:handoff)
    expect(candidate.category).to eq(:knowledge)
    expect(candidate.constraint.selectable?).to be(true)
    expect(candidate.constraint.origin).to eq(:handoff_context)
    expect(candidate.metadata["handoff_policy_category"]).to eq("knowledge")
    expect(candidate.metadata["handoff_provenance"]).to eq(provenance.to_h)
  end

  it "keeps all members of one Tool exchange selection unit together" do
    source = build_agent("projection-tool-source")
    target = build_agent("projection-tool-target")
    handoff = Phronomy::MultiAgent::Handoff.new(source_agent: source, target_agent: target, policy: policy)
    assistant_ref = source.persistence.contents.put_json(
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [{"id" => "tc-1", "name" => "lookup", "arguments" => {}}]
    )
    tool_ref = source.persistence.contents.put_json(
      "role" => "tool",
      "content" => "result",
      "tool_call_id" => "tc-1"
    )
    unit_metadata = {
      "selection_unit_id" => "tool-exchange-1",
      "selection_unit_kind" => "tool_exchange",
      "handoff_policy_category" => "tool_exchanges",
      "source_agent_id" => source.agent_id
    }
    source_manifest = manifest(source.persistence, [
      segment(
        position: 0,
        category: :assistant_message,
        role: :assistant,
        content_ref: assistant_ref,
        metadata: unit_metadata
      ),
      segment(
        position: 1,
        category: :tool_message,
        role: :tool,
        content_ref: tool_ref,
        tool_call_id: "tc-1",
        metadata: unit_metadata
      )
    ])

    context = described_class.new.build(
      request: request(handoff, selection_intent: {tool_exchanges: true}),
      manifest: source_manifest,
      persistence: source.persistence,
      source_agent: source
    )

    expect(context.items.length).to eq(2)
    expect(context.items.map(&:policy_category).uniq).to eq([:tool_exchanges])
    expect(context.items.map(&:candidate_category)).to contain_exactly(
      :assistant_message,
      :tool_message
    )
  end

  it "groups current-format Context conversation segments without Selection::Unit" do
    persistence = Phronomy::Persistence::InMemory.new
    first_ref = persistence.contents.put_text("first")
    second_ref = persistence.contents.put_text("second")
    group_metadata = {
      "context_policy_conversation_group_id" => "conversation:2:3",
      "handoff_policy_category" => "history"
    }
    current_manifest = manifest(persistence, [
      segment(
        position: 0,
        category: :external_message,
        content_ref: first_ref,
        metadata: group_metadata
      ),
      segment(
        position: 1,
        category: :external_message,
        content_ref: second_ref,
        metadata: group_metadata
      )
    ])

    groups = described_class.new.send(:project_visible_groups, current_manifest)

    expect(groups.length).to eq(1)
    expect(groups.values.first.fetch(:segments).map(&:position)).to eq([0, 1])
  end
  it "classifies current-format semantic Conversation as Handoff history independently of kind" do
    source = build_agent("projection-semantic-conversation-source")
    target = build_agent("projection-semantic-conversation-target")
    handoff = Phronomy::MultiAgent::Handoff.new(
      source_agent: source,
      target_agent: target,
      policy: policy
    )
    content_ref = source.persistence.contents.put_text("APPLICATION_CONVERSATION_MARKER")
    source_manifest = manifest(source.persistence, [
      segment(
        position: 0,
        category: :application_note,
        content_ref: content_ref,
        metadata: {
          "context_policy_semantic_category" => "conversation",
          "context_policy_conversation_group_id" => "conversation:1:0"
        }
      )
    ])

    context = described_class.new.build(
      request: request(handoff),
      manifest: source_manifest,
      persistence: source.persistence,
      source_agent: source
    )

    expect(context.items.length).to eq(1)
    expect(context.items.first.policy_category).to eq(:history)
    expect(context.items.first.candidate_category).to eq(:application_note)
    expect(context.items.first.content).to eq("APPLICATION_CONVERSATION_MARKER")
    expect(context.items.first.metadata["context_policy_semantic_category"])
      .to eq("conversation")
  end
  it "preserves current-format JSON content for an Application-specific kind" do
    source = build_agent("projection-json-format-source")
    target = build_agent("projection-json-format-target")
    handoff = Phronomy::MultiAgent::Handoff.new(
      source_agent: source,
      target_agent: target,
      policy: policy
    )
    payload = {"type" => "application_note", "value" => 42}
    content_ref = source.persistence.contents.put_json(payload)
    source_manifest = manifest(source.persistence, [
      segment(
        position: 0,
        category: :application_note,
        content_ref: content_ref,
        metadata: {
          "context_policy_semantic_category" => "conversation",
          "context_policy_content_format" => "json",
          "context_policy_conversation_group_id" => "conversation:1:0"
        }
      )
    ])

    context = described_class.new.build(
      request: request(handoff),
      manifest: source_manifest,
      persistence: source.persistence,
      source_agent: source
    )

    item = context.items.fetch(0)
    expect(item.policy_category).to eq(:history)
    expect(item.candidate_category).to eq(:application_note)
    expect(item.content_format).to eq(:json)
    expect(item.content).to eq(payload)
    expect(item.metadata["context_policy_semantic_category"]).to eq("conversation")
    expect(item.metadata).not_to have_key("context_policy_content_format")
  end

  it "falls back to legacy kind-based content format when metadata is absent" do
    source = build_agent("projection-legacy-format-source")
    target = build_agent("projection-legacy-format-target")
    handoff = Phronomy::MultiAgent::Handoff.new(
      source_agent: source,
      target_agent: target,
      policy: policy
    )
    content_ref = source.persistence.contents.put_json(
      "role" => "assistant",
      "content" => "legacy"
    )
    source_manifest = manifest(source.persistence, [
      segment(
        position: 0,
        category: :assistant_message,
        role: :assistant,
        content_ref: content_ref,
        metadata: {}
      )
    ])

    context = described_class.new.build(
      request: request(handoff),
      manifest: source_manifest,
      persistence: source.persistence,
      source_agent: source
    )

    expect(context.items.fetch(0).content_format).to eq(:json)
    expect(context.items.fetch(0).content).to include("role" => "assistant")
  end
end
