# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Context Policy branch coverage" do
  let(:provenance) do
    Phronomy::Context::ContextPolicyInput::Provenance.new(origin: :journal)
  end

  def conversation_item(id:, kind:, sequence:, tool_call_id: nil, tool_call_ids: [], required: false)
    content = if kind == :assistant_message
      {"role" => "assistant", "content" => nil,
       "tool_calls" => tool_call_ids.map { |call_id| {"id" => call_id, "name" => "tool", "arguments" => {}} }}
    elsif kind == :tool_message
      {"role" => "tool", "content" => "ok", "tool_call_id" => tool_call_id}
    else
      id
    end
    Phronomy::Context::ContextPolicyInput::ConversationItem.new(
      id: id, kind: kind, role: ((kind == :tool_message) ? :tool : :assistant),
      content: content, content_format: content.is_a?(String) ? :text : :json,
      sequence: sequence, estimated_tokens: 5, required: required,
      provenance: provenance, tool_call_id: tool_call_id,
      tool_call_ids: tool_call_ids, delivery: :chat_message, metadata: {}
    )
  end

  def empty_input(conversation: [])
    Phronomy::Context::ContextPolicyInput.new(
      agent_id: "a", execution_id: "e", call_sequence: 1, call_mode: :complete,
      instruction: [], knowledge: [], tools: [], conversation: conversation,
      token_budget: nil, model_config: {}, previous_manifest: nil, metadata: {}
    )
  end

  describe Phronomy::Context::ContextPlanValidator do
    it "rejects a non-ContextPlan" do
      expect { described_class.new.validate!(input: empty_input, plan: Object.new) }
        .to raise_error(ArgumentError, /expected.*ContextPlan/)
    end

    it "rejects duplicate Plan item IDs" do
      item = conversation_item(id: "same", kind: :external_message, sequence: 1)
      policy_input = empty_input(conversation: [[item]])
      generated = Phronomy::Context::ContextPolicyInput::KnowledgeItem.new(
        id: "same", kind: :knowledge, role: :user, content: "x",
        content_format: :text, estimated_tokens: 1, required: false,
        provenance: Phronomy::Context::ContextPolicyInput::Provenance.new(origin: :policy_generated),
        metadata: {}
      )
      plan = Phronomy::Context::ContextPlan.new(
        knowledge: [generated], conversation: [[item]]
      )

      expect { described_class.new.validate!(input: policy_input, plan: plan) }
        .to raise_error(ArgumentError, /duplicate item IDs/)
    end

    it "rejects omission of a required conversation group" do
      item = conversation_item(id: "required", kind: :external_message, sequence: 1, required: true)
      policy_input = empty_input(conversation: [[item]])

      expect {
        described_class.new.validate!(input: policy_input, plan: Phronomy::Context::ContextPlan.new)
      }.to raise_error(Phronomy::Context::BudgetExceededError, /required conversation/)
    end
  end

  describe Phronomy::Context::ContextPolicyInputBuilder do
    def candidate(id:, category:, sequence:, tool_call_id: nil, tool_call_ids: [])
      Phronomy::Context::Candidate.new(
        candidate_id: id, source_kind: :working, category: category,
        role: ((category == :tool_message) ? :tool : :assistant),
        content_ref: "ref-#{id}", record_id: "record-#{id}", agent_id: "a",
        execution_id: "e", llm_call_id: "llm", tool_call_id: tool_call_id,
        sequence: sequence,
        constraint: Phronomy::Context::Constraint.selectable(origin: :context_policy),
        priority: 0,
        metadata: {"estimated_tokens" => 5, "tool_call_ids" => tool_call_ids}
      )
    end

    it "groups an assistant Tool Call and Tool message atomically and marks latest current exchange required" do
      contents = {
        "ref-assistant" => Phronomy::CanonicalJSON.dump(
          "role" => "assistant", "content" => nil,
          "tool_calls" => [{"id" => "tc", "name" => "tool", "arguments" => {}}]
        ),
        "ref-tool" => Phronomy::CanonicalJSON.dump(
          "role" => "tool", "content" => "ok", "tool_call_id" => "tc"
        )
      }
      builder = described_class.new(content_loader: ->(ref) { contents.fetch(ref) })
      result = builder.build(
        agent_id: "a", execution_id: "e", call_sequence: 2, call_mode: :complete,
        candidates: [
          candidate(id: "assistant", category: :assistant_message, sequence: 1, tool_call_ids: ["tc"]),
          candidate(id: "tool", category: :tool_message, sequence: 2, tool_call_id: "tc")
        ],
        instruction: [], tools: [], current_input: nil, token_budget: nil,
        model_config: {}, previous_manifest: nil
      )

      expect(result.conversation.length).to eq(1)
      expect(result.conversation.first.map(&:id)).to eq(%w[assistant tool])
      expect(result.conversation.first).to all(be_required)
    end

    it "rejects an orphan Tool message" do
      contents = {
        "ref-tool" => Phronomy::CanonicalJSON.dump(
          "role" => "tool", "content" => "ok", "tool_call_id" => "tc"
        )
      }
      builder = described_class.new(content_loader: ->(ref) { contents.fetch(ref) })

      expect {
        builder.build(
          agent_id: "a", execution_id: "e", call_sequence: 2, call_mode: :complete,
          candidates: [candidate(id: "tool", category: :tool_message, sequence: 1, tool_call_id: "tc")],
          instruction: [], tools: [], current_input: nil, token_budget: nil,
          model_config: {}, previous_manifest: nil
        )
      }.to raise_error(ArgumentError, /orphan Tool message/)
    end
  end

  describe "LLM response values" do
    it "rejects opaque content instead of stringifying it" do
      expect { Phronomy::LLMAdapter::Response.new(content: Object.new) }.to raise_error(ArgumentError)
    end

    it "round-trips canonical calls and metadata without SDK construction" do
      outcome = Phronomy::LLMAdapter::Response.from_h(content: "hi",
        tool_calls: [{"id" => "c1", "name" => "tool", "arguments" => {}}],
        metadata: {"model_id" => "model"})
      expect(outcome.tool_calls.first.id).to eq("c1")
      expect(Phronomy::LLMAdapter::Response.from_h(outcome.to_h).to_h).to eq(outcome.to_h)
    end
  end

  describe "ContextPolicyInput validation edge cases" do
    let(:instruction_item) do
      Phronomy::Context::ContextPolicyInput::InstructionItem.new(
        id: "instr-1", kind: :instruction, role: :system, content: "Hello",
        content_format: :text, estimated_tokens: 2, required: true,
        provenance: provenance, metadata: {}
      )
    end

    it "rejects non-positive call_sequence" do
      expect {
        Phronomy::Context::ContextPolicyInput.new(
          agent_id: "a", execution_id: "e", call_sequence: 0, call_mode: :complete,
          instruction: [], knowledge: [], tools: [], conversation: [],
          token_budget: nil, model_config: {}, previous_manifest: nil, metadata: {}
        )
      }.to raise_error(ArgumentError, /call_sequence must be positive/)
    end

    it "rejects unknown call_mode" do
      expect {
        Phronomy::Context::ContextPolicyInput.new(
          agent_id: "a", execution_id: "e", call_sequence: 1, call_mode: :unknown_mode,
          instruction: [], knowledge: [], tools: [], conversation: [],
          token_budget: nil, model_config: {}, previous_manifest: nil, metadata: {}
        )
      }.to raise_error(ArgumentError, /unknown.*call_mode/)
    end

    it "rejects empty conversation group" do
      expect {
        Phronomy::Context::ContextPolicyInput.new(
          agent_id: "a", execution_id: "e", call_sequence: 1, call_mode: :complete,
          instruction: [], knowledge: [], tools: [], conversation: [[]],
          token_budget: nil, model_config: {}, previous_manifest: nil, metadata: {}
        )
      }.to raise_error(ArgumentError, /groups must not be empty/)
    end

    it "rejects a ToolItem with a non-Hash definition" do
      expect {
        Phronomy::Context::ContextPolicyInput::ToolItem.new(
          id: "tool-1", definition: "not-a-hash", estimated_tokens: 3, required: false,
          provenance: provenance, metadata: {}
        )
      }.to raise_error(ArgumentError, /definition requires a non-empty name/)
    end

    it "rejects negative estimated_tokens on an InstructionItem" do
      expect {
        Phronomy::Context::ContextPolicyInput::InstructionItem.new(
          id: "instr-1", kind: :instruction, role: :system, content: "Hi",
          content_format: :text, estimated_tokens: -1, required: false,
          provenance: provenance, metadata: {}
        )
      }.to raise_error(ArgumentError, /estimated_tokens must be non-negative/)
    end

    it "rejects reserved metadata keys on a Policy-generated Plan item" do
      generated = Phronomy::Context::ContextPolicyInput::ConversationItem.new(
        id: "gen-1", kind: :external_message, role: :user, content: "Hi",
        content_format: :text, sequence: 1, estimated_tokens: 2, required: false,
        provenance: Phronomy::Context::ContextPolicyInput::Provenance.new(origin: :policy_generated),
        tool_call_id: nil, tool_call_ids: [], delivery: :chat_message,
        metadata: {"context_policy_origin" => "app"}
      )
      plan = Phronomy::Context::ContextPlan.new(conversation: [[generated]])
      expect {
        Phronomy::Context::ContextPlanValidator.new.validate!(input: empty_input, plan: plan)
      }.to raise_error(ArgumentError, /Framework-reserved key/)
    end

    it "rejects a Provenance value of the wrong type" do
      expect {
        Phronomy::Context::ContextPolicyInput::InstructionItem.new(
          id: "instr-1", kind: :instruction, role: :system, content: "Hi",
          content_format: :text, estimated_tokens: 2, required: false,
          provenance: 42, metadata: {}
        )
      }.to raise_error(ArgumentError, /provenance must be Provenance or Hash/)
    end
  end

  describe "ContextPlanValidator additional error paths" do
    it "rejects validate! when input is not a ContextPolicyInput" do
      expect {
        Phronomy::Context::ContextPlanValidator.new.validate!(input: "wrong", plan: Phronomy::Context::ContextPlan.new)
      }.to raise_error(ArgumentError, /ContextPlanValidator expected ContextPolicyInput/)
    end

    it "rejects a Plan conversation group containing a non-ConversationItem" do
      input = empty_input
      bad_group = [Phronomy::Context::ContextPolicyInput::InstructionItem.new(
        id: "x", kind: :instruction, role: :system, content: "X",
        content_format: :text, estimated_tokens: 1, required: false,
        provenance: provenance, metadata: {}
      )]
      plan = Phronomy::Context::ContextPlan.new(conversation: [bad_group])
      expect {
        Phronomy::Context::ContextPlanValidator.new.validate!(input: input, plan: plan)
      }.to raise_error(ArgumentError, /non-ConversationItem/)
    end

    it "rejects a Plan conversation with an empty group" do
      input = empty_input
      plan = Phronomy::Context::ContextPlan.new(conversation: [[]])
      expect {
        Phronomy::Context::ContextPlanValidator.new.validate!(input: input, plan: plan)
      }.to raise_error(ArgumentError, /non-empty Arrays/)
    end

    it "rejects a Plan conversation with a modified input item" do
      item = conversation_item(id: "c1", kind: :external_message, sequence: 1)
      input = empty_input(conversation: [[item]])
      modified = Phronomy::Context::ContextPolicyInput::ConversationItem.new(
        id: "c1", kind: :external_message, role: :user,
        content: "modified", content_format: :text, sequence: 1,
        estimated_tokens: 99, required: false, provenance: provenance,
        tool_call_id: nil, tool_call_ids: [], delivery: :chat_message, metadata: {}
      )
      plan = Phronomy::Context::ContextPlan.new(conversation: [[modified]])
      expect {
        Phronomy::Context::ContextPlanValidator.new.validate!(input: input, plan: plan)
      }.to raise_error(ArgumentError, /modified an input conversation group/)
    end

    it "rejects a Policy-generated group with non-policy-generated provenance" do
      generated_with_wrong_origin = Phronomy::Context::ContextPolicyInput::ConversationItem.new(
        id: "gen-1", kind: :external_message, role: :user,
        content: "generated", content_format: :text, sequence: 2,
        estimated_tokens: 3, required: false,
        provenance: Phronomy::Context::ContextPolicyInput::Provenance.new(origin: :journal),
        tool_call_id: nil, tool_call_ids: [], delivery: :chat_message, metadata: {}
      )
      plan = Phronomy::Context::ContextPlan.new(conversation: [[generated_with_wrong_origin]])
      expect {
        Phronomy::Context::ContextPlanValidator.new.validate!(input: empty_input, plan: plan)
      }.to raise_error(ArgumentError, /contains unknown conversation item/)
    end

    it "rejects all-policy-generated group where not all items have policy_generated origin" do
      item1 = Phronomy::Context::ContextPolicyInput::ConversationItem.new(
        id: "gen-1", kind: :external_message, role: :user, content: "A",
        content_format: :text, sequence: 1, estimated_tokens: 1, required: false,
        provenance: Phronomy::Context::ContextPolicyInput::Provenance.new(origin: :policy_generated),
        tool_call_id: nil, tool_call_ids: [], delivery: :chat_message, metadata: {}
      )
      item2 = Phronomy::Context::ContextPolicyInput::ConversationItem.new(
        id: "gen-2", kind: :external_message, role: :user, content: "B",
        content_format: :text, sequence: 2, estimated_tokens: 1, required: false,
        provenance: Phronomy::Context::ContextPolicyInput::Provenance.new(origin: :journal),
        tool_call_id: nil, tool_call_ids: [], delivery: :chat_message, metadata: {}
      )
      plan = Phronomy::Context::ContextPlan.new(conversation: [[item1, item2]])
      expect {
        Phronomy::Context::ContextPlanValidator.new.validate!(input: empty_input, plan: plan)
      }.to raise_error(ArgumentError, /contains unknown conversation item/)
    end

    it "rejects a Plan instruction item that is not an InstructionItem" do
      wrong = Phronomy::Context::ContextPolicyInput::KnowledgeItem.new(
        id: "k1", kind: :knowledge, role: :user, content: "Know",
        content_format: :text, estimated_tokens: 2, required: false,
        provenance: provenance, metadata: {}
      )
      plan = Phronomy::Context::ContextPlan.new(instruction: [wrong])
      input = empty_input
      expect {
        Phronomy::Context::ContextPlanValidator.new.validate!(input: input, plan: plan)
      }.to raise_error(ArgumentError, /expected.*InstructionItem/)
    end

    it "rejects a Plan instruction item that differs from its input source" do
      orig = Phronomy::Context::ContextPolicyInput::InstructionItem.new(
        id: "instr-1", kind: :instruction, role: :system, content: "Original",
        content_format: :text, estimated_tokens: 5, required: true,
        provenance: provenance, metadata: {}
      )
      modified = Phronomy::Context::ContextPolicyInput::InstructionItem.new(
        id: "instr-1", kind: :instruction, role: :system, content: "Modified",
        content_format: :text, estimated_tokens: 5, required: true,
        provenance: provenance, metadata: {}
      )
      input = Phronomy::Context::ContextPolicyInput.new(
        agent_id: "a", execution_id: "e", call_sequence: 1, call_mode: :complete,
        instruction: [orig], knowledge: [], tools: [], conversation: [],
        token_budget: nil, model_config: {}, previous_manifest: nil, metadata: {}
      )
      plan = Phronomy::Context::ContextPlan.new(instruction: [modified])
      expect {
        Phronomy::Context::ContextPlanValidator.new.validate!(input: input, plan: plan)
      }.to raise_error(ArgumentError, /modified input item/)
    end

    it "raises ContextBudgetExceededError when Plan omits a required instruction" do
      req = Phronomy::Context::ContextPolicyInput::InstructionItem.new(
        id: "req-1", kind: :instruction, role: :system, content: "Must include",
        content_format: :text, estimated_tokens: 5, required: true,
        provenance: provenance, metadata: {}
      )
      input = Phronomy::Context::ContextPolicyInput.new(
        agent_id: "a", execution_id: "e", call_sequence: 1, call_mode: :complete,
        instruction: [req], knowledge: [], tools: [], conversation: [],
        token_budget: nil, model_config: {}, previous_manifest: nil, metadata: {}
      )
      plan = Phronomy::Context::ContextPlan.new(instruction: [])
      expect {
        Phronomy::Context::ContextPlanValidator.new.validate!(input: input, plan: plan)
      }.to raise_error(Phronomy::Context::BudgetExceededError, /required.*instruction/)
    end

    it "accepts nil execution_id in ContextPolicyInput" do
      input = Phronomy::Context::ContextPolicyInput.new(
        agent_id: "a", execution_id: nil, call_sequence: 1, call_mode: :complete,
        instruction: [], knowledge: [], tools: [], conversation: [],
        token_budget: nil, model_config: {}, previous_manifest: nil, metadata: {}
      )
      expect(input.execution_id).to be_nil
    end

    it "rejects a Plan knowledge item that is not a KnowledgeItem" do
      wrong = Phronomy::Context::ContextPolicyInput::InstructionItem.new(
        id: "k1", kind: :instruction, role: :system, content: "Hi",
        content_format: :text, estimated_tokens: 2, required: false,
        provenance: provenance, metadata: {}
      )
      plan = Phronomy::Context::ContextPlan.new(knowledge: [wrong])
      input = empty_input
      expect {
        Phronomy::Context::ContextPlanValidator.new.validate!(input: input, plan: plan)
      }.to raise_error(ArgumentError, /expected.*KnowledgeItem/)
    end

    it "rejects a ConversationItem with an unknown delivery in the constructor" do
      expect {
        Phronomy::Context::ContextPolicyInput::ConversationItem.new(
          id: "c1", kind: :external_message, role: :user, content: "Hi",
          content_format: :text, sequence: 1, estimated_tokens: 2, required: false,
          provenance: provenance, tool_call_id: nil, tool_call_ids: [],
          delivery: :pony, metadata: {}
        )
      }.to raise_error(ArgumentError, /unknown ContextPolicyInput delivery/)
    end

    it "rejects a ContextPolicyInput with wrong item type in instructions" do
      wrong = Phronomy::Context::ContextPolicyInput::KnowledgeItem.new(
        id: "k1", kind: :knowledge, role: :user, content: "K",
        content_format: :text, estimated_tokens: 2, required: false,
        provenance: provenance, metadata: {}
      )
      expect {
        Phronomy::Context::ContextPolicyInput.new(
          agent_id: "a", execution_id: "e", call_sequence: 1, call_mode: :complete,
          instruction: [wrong], knowledge: [], tools: [], conversation: [],
          token_budget: nil, model_config: {}, previous_manifest: nil, metadata: {}
        )
      }.to raise_error(ArgumentError, /instruction contains/)
    end

    it "rejects a ToolItem with empty id" do
      expect {
        Phronomy::Context::ContextPolicyInput::ToolItem.new(
          id: "", definition: {"name" => "my_tool"}, estimated_tokens: 3, required: false,
          provenance: provenance, metadata: {}
        )
      }.to raise_error(ArgumentError, /ToolItem id must not be empty/)
    end

    it "rejects an InstructionItem with empty id" do
      expect {
        Phronomy::Context::ContextPolicyInput::InstructionItem.new(
          id: "", kind: :instruction, role: :system, content: "Hi",
          content_format: :text, estimated_tokens: 2, required: false,
          provenance: provenance, metadata: {}
        )
      }.to raise_error(ArgumentError, /item id must not be empty/)
    end

    it "rejects an InstructionItem with unknown content_format" do
      expect {
        Phronomy::Context::ContextPolicyInput::InstructionItem.new(
          id: "i1", kind: :instruction, role: :system, content: "Hi",
          content_format: :binary, estimated_tokens: 2, required: false,
          provenance: provenance, metadata: {}
        )
      }.to raise_error(ArgumentError, /unknown ContextPolicyInput content format/)
    end

    it "builds Provenance from a Hash" do
      item = Phronomy::Context::ContextPolicyInput::InstructionItem.new(
        id: "i1", kind: :instruction, role: :system, content: "Hi",
        content_format: :text, estimated_tokens: 2, required: false,
        provenance: {origin: :journal, content_ref: "sha256:abc"}, metadata: {}
      )
      expect(item.provenance).to be_a(Phronomy::Context::ContextPolicyInput::Provenance)
      expect(item.provenance.origin).to eq(:journal)
    end

    it "rejects a Policy-generated group with mixed protocol and non-protocol items" do
      gen_prov = Phronomy::Context::ContextPolicyInput::Provenance.new(origin: :policy_generated)
      assistant = Phronomy::Context::ContextPolicyInput::ConversationItem.new(
        id: "a1", kind: :assistant_message, role: :assistant,
        content: {"role" => "assistant", "content" => nil, "tool_calls" => [{"id" => "call-1", "name" => "t", "arguments" => {}}]},
        content_format: :json, sequence: 1, estimated_tokens: 5, required: false,
        provenance: gen_prov, tool_call_id: nil, tool_call_ids: ["call-1"],
        delivery: :chat_message, metadata: {}
      )
      non_protocol = Phronomy::Context::ContextPolicyInput::ConversationItem.new(
        id: "e1", kind: :external_message, role: :user, content: "Hi",
        content_format: :text, sequence: 2, estimated_tokens: 2, required: false,
        provenance: gen_prov, tool_call_id: nil, tool_call_ids: [],
        delivery: :chat_message, metadata: {}
      )
      plan = Phronomy::Context::ContextPlan.new(conversation: [[assistant, non_protocol]])
      expect {
        Phronomy::Context::ContextPlanValidator.new.validate!(input: empty_input, plan: plan)
      }.to raise_error(ArgumentError, /only assistant_message and tool_message/)
    end
  end
end
