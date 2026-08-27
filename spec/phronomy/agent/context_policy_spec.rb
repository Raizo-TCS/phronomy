# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Context Policy semantic API" do
  let(:provenance) do
    Phronomy::Agent::ContextPolicyInput::Provenance.new(origin: :journal)
  end

  def instruction(id: "i1", tokens: 5, required: true)
    Phronomy::Agent::ContextPolicyInput::InstructionItem.new(
      id: id, kind: :instruction, role: :system, content: "instruction",
      content_format: :text, estimated_tokens: tokens, required: required,
      provenance: provenance, metadata: {}
    )
  end

  def knowledge(id:, tokens:, required: false)
    Phronomy::Agent::ContextPolicyInput::KnowledgeItem.new(
      id: id, kind: :knowledge, role: :user, content: id,
      content_format: :text, estimated_tokens: tokens, required: required,
      provenance: provenance, metadata: {}
    )
  end

  def conversation(id:, sequence:, tokens:, required: false)
    Phronomy::Agent::ContextPolicyInput::ConversationItem.new(
      id: id, kind: :external_message, role: :user, content: id,
      content_format: :text, sequence: sequence, estimated_tokens: tokens,
      required: required, provenance: provenance, tool_call_id: nil,
      tool_call_ids: [], delivery: :chat_message, metadata: {}
    )
  end

  def input(
    instruction_items: [instruction],
    knowledge_items: [],
    tool_items: [],
    conversation_groups: [],
    context_window: 100,
    max_output_tokens: 0
  )
    Phronomy::Agent::ContextPolicyInput.new(
      agent_id: "agent-1",
      execution_id: "execution-1",
      call_sequence: 1,
      call_mode: :complete,
      instruction: instruction_items,
      knowledge: knowledge_items,
      tools: tool_items,
      conversation: conversation_groups,
      token_budget: Phronomy::LlmContextWindow::TokenBudget.new(
        context_window: context_window,
        max_output_tokens: max_output_tokens
      ),
      model_config: {},
      previous_manifest: nil,
      metadata: {}
    )
  end

  it "binds one ContextPolicy instance on the Agent class and inherits it" do
    policy = Class.new(Phronomy::Agent::ContextPolicy) do
      def call(input)
        Phronomy::Agent::ContextPlan.new(
          instruction: input.instruction,
          knowledge: input.knowledge,
          tools: input.tools,
          conversation: input.conversation
        )
      end
    end.new
    parent = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "context-policy-binding-parent", version: 1
      context_policy policy
    end
    child = Class.new(parent)

    expect(parent.context_policy).to equal(policy)
    expect(child.context_policy).to equal(policy)
  end

  it "uses the built-in Default instance when the Agent class has no binding" do
    klass = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "context-policy-default-binding", version: 1
    end

    expect(klass.context_policy).to equal(Phronomy::Agent::ContextPolicies::Default.instance)
  end

  it "rejects a ContextPolicy class because the binding contract requires an instance" do
    klass = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "context-policy-instance-only", version: 1
    end

    expect { klass.context_policy(Phronomy::Agent::ContextPolicies::Default) }
      .to raise_error(ArgumentError, /ContextPolicy instance/)
  end

  it "uses four typed semantic categories without request parts or descriptors" do
    policy_input = input

    expect(policy_input.instruction.first)
      .to be_a(Phronomy::Agent::ContextPolicyInput::InstructionItem)
    expect(policy_input.knowledge).to eq([])
    expect(policy_input.tools).to eq([])
    expect(policy_input.conversation).to eq([])
    expect(policy_input).not_to respond_to(:parts)
    expect(policy_input).not_to respond_to(:candidates)
    expect(Phronomy::Agent::ContextPolicies::Default.instance).not_to respond_to(:descriptor)
  end

  it "keeps conversation groups indivisible" do
    first = conversation(id: "assistant", sequence: 1, tokens: 5)
    second = conversation(id: "tool", sequence: 2, tokens: 5)
    policy_input = input(conversation_groups: [[first, second]])
    invalid = Phronomy::Agent::ContextPlan.new(
      instruction: policy_input.instruction,
      knowledge: [], tools: [], conversation: [[first]]
    )

    expect {
      Phronomy::Agent::ContextPlanValidator.new.validate!(input: policy_input, plan: invalid)
    }.to raise_error(ArgumentError, /split, merged, or reordered/)
  end

  it "permits Policy-generated Knowledge without Framework source-item provenance" do
    policy_class = Class.new(Phronomy::Agent::ContextPolicy) do
      def call(input)
        generated = knowledge_item(content: "derived summary", metadata: {"kind" => "summary"})
        plan(
          instruction: input.instruction,
          knowledge: [generated],
          tools: input.tools,
          conversation: input.conversation
        )
      end
    end
    policy_input = input
    plan = policy_class.new.call(policy_input)

    expect(plan.knowledge.first.provenance.origin).to eq(:policy_generated)
    expect {
      Phronomy::Agent::ContextPlanValidator.new.validate!(input: policy_input, plan: plan)
    }.not_to raise_error
  end

  it "does not allow a Policy to invent a runtime Tool definition" do
    generated_tool = Phronomy::Agent::ContextPolicyInput::ToolItem.new(
      id: "tool:invented",
      definition: {"name" => "invented"},
      estimated_tokens: 1,
      required: false,
      provenance: Phronomy::Agent::ContextPolicyInput::Provenance.new(origin: :policy_generated),
      metadata: {}
    )
    policy_input = input
    plan = Phronomy::Agent::ContextPlan.new(
      instruction: policy_input.instruction,
      tools: [generated_tool]
    )

    expect {
      Phronomy::Agent::ContextPlanValidator.new.validate!(input: policy_input, plan: plan)
    }.to raise_error(ArgumentError, /unknown tools item/)
  end

  it "rejects malformed Tool protocol in a Policy-generated conversation group" do
    policy_class = Class.new(Phronomy::Agent::ContextPolicy) do
      def call(input)
        generated = conversation_item(
          content: {
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [{"id" => "tc-1", "name" => "tool", "arguments" => {}}]
          },
          role: :assistant,
          kind: :assistant_message,
          tool_call_ids: ["tc-1"]
        )
        plan(instruction: input.instruction, conversation: [[generated]])
      end
    end
    policy_input = input
    invalid = policy_class.new.call(policy_input)

    expect {
      Phronomy::Agent::ContextPlanValidator.new.validate!(input: policy_input, plan: invalid)
    }.to raise_error(ArgumentError, /has no Tool message/)
  end

  it "rejects non-canonical Policy-generated assistant messages before Manifest commit" do
    policy_class = Class.new(Phronomy::Agent::ContextPolicy) do
      def call(input)
        generated = conversation_item(
          content: "not canonical JSON",
          role: :assistant,
          kind: :assistant_message
        )
        plan(instruction: input.instruction, conversation: [[generated]])
      end
    end
    policy_input = input
    invalid = policy_class.new.call(policy_input)

    expect {
      Phronomy::Agent::ContextPlanValidator.new.validate!(input: policy_input, plan: invalid)
    }.to raise_error(ArgumentError, /canonical JSON message content/)
  end

  it "rejects a Policy-generated Tool message ordered before its assistant Tool Call" do
    policy_class = Class.new(Phronomy::Agent::ContextPolicy) do
      def call(input)
        assistant = conversation_item(
          content: {
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              {"id" => "tc-1", "name" => "lookup", "arguments" => {}}
            ]
          },
          role: :assistant,
          kind: :assistant_message,
          tool_call_ids: ["tc-1"]
        )
        tool = conversation_item(
          content: {
            "role" => "tool",
            "content" => "result",
            "tool_call_id" => "tc-1"
          },
          role: :tool,
          kind: :tool_message,
          tool_call_id: "tc-1"
        )
        plan(instruction: input.instruction, conversation: [[tool, assistant]])
      end
    end
    policy_input = input
    invalid = policy_class.new.call(policy_input)

    expect {
      Phronomy::Agent::ContextPlanValidator.new.validate!(input: policy_input, plan: invalid)
    }.to raise_error(ArgumentError, /must follow its assistant Tool Call/)
  end

  it "accepts a canonical Policy-generated Tool exchange in protocol order" do
    policy_class = Class.new(Phronomy::Agent::ContextPolicy) do
      def call(input)
        assistant = conversation_item(
          content: {
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              {"id" => "tc-1", "name" => "lookup", "arguments" => {}}
            ]
          },
          role: :assistant,
          kind: :assistant_message,
          tool_call_ids: ["tc-1"]
        )
        tool = conversation_item(
          content: {
            "role" => "tool",
            "content" => "result",
            "tool_call_id" => "tc-1"
          },
          role: :tool,
          kind: :tool_message,
          tool_call_id: "tc-1"
        )
        plan(instruction: input.instruction, conversation: [[assistant, tool]])
      end
    end
    policy_input = input
    valid = policy_class.new.call(policy_input)

    expect {
      Phronomy::Agent::ContextPlanValidator.new.validate!(input: policy_input, plan: valid)
    }.not_to raise_error
  end

  it "traces only the ContextPolicy invocation boundary by default" do
    events = []
    tracer = Object.new
    tracer.define_singleton_method(:start_span) do |name, **attributes|
      events << [:start, name, attributes]
      Object.new
    end
    tracer.define_singleton_method(:finish_span) do |_span, **attributes|
      events << [:finish, attributes]
    end
    policy = Class.new(Phronomy::Agent::ContextPolicy) do
      def call(input)
        Phronomy::Agent::ContextPlan.new(
          instruction: input.instruction,
          knowledge: input.knowledge,
          tools: input.tools,
          conversation: input.conversation
        )
      end
    end.new
    agent_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "context-policy-tracing", version: 1
      context_policy policy
    end
    agent = agent_class.new
    assembler = Phronomy::Agent::ContextAssembler.new(
      agent: agent,
      persistence: agent.persistence
    )
    allow(Phronomy.configuration).to receive(:tracer).and_return(tracer)

    result = assembler.send(:invoke_policy, input)

    expect(result).to be_a(Phronomy::Agent::ContextPlan)
    expect(events.first[0, 2]).to eq([:start, "context_policy"])
    expect(events.first.fetch(2)).to include(
      agent_id: "agent-1", execution_id: "execution-1", call_sequence: 1
    )
    expect(events.last).to eq([:finish, {}])
  end

  it "Default retains instructions, takes recent contiguous conversation, and stable-fit Knowledge" do
    policy_input = input(
      knowledge_items: [
        knowledge(id: "k-large", tokens: 40),
        knowledge(id: "k-small", tokens: 5)
      ],
      conversation_groups: [
        [conversation(id: "old", sequence: 1, tokens: 40)],
        [conversation(id: "recent", sequence: 2, tokens: 10, required: true)]
      ],
      context_window: 35
    )

    plan = Phronomy::Agent::ContextPolicies::Default.instance.call(policy_input)

    expect(plan.instruction.map(&:id)).to eq(["i1"])
    expect(plan.conversation.flatten.map(&:id)).to eq(["recent"])
    expect(plan.knowledge.map(&:id)).to eq(["k-small"])
  end

  it "Default fails instead of omitting required Context" do
    policy_input = input(
      conversation_groups: [
        [conversation(id: "current", sequence: 1, tokens: 100, required: true)]
      ],
      context_window: 50
    )

    expect { Phronomy::Agent::ContextPolicies::Default.instance.call(policy_input) }
      .to raise_error(Phronomy::ContextBudgetExceededError, /Required Context/)
  end
end
