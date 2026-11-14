# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Public Context Policy budgeting" do
  let(:policy_class) do
    Class.new(Phronomy::Context::ContextPolicy) do
      def estimates(content)
        [
          estimate_tokens(content),
          instruction_item(content: content).estimated_tokens,
          knowledge_item(content: content).estimated_tokens,
          conversation_item(content: content, role: :user).estimated_tokens
        ]
      end
    end
  end

  def policy_input(limit: 100)
    types = Phronomy::Context::ContextPolicyInput
    instruction = types::InstructionItem.new(id: "instruction", kind: :instruction,
      role: :system, content: "Review the task", estimated_tokens: 10, required: true)
    history = [20, 20, 20].each_with_index.map do |cost, index|
      [types::ConversationItem.new(id: "message-#{index}", kind: :external_message,
        role: :user, content: "History #{index}", estimated_tokens: cost, sequence: index)]
    end
    types.new(agent_id: "policy-budget-agent", execution_id: "execution-1",
      call_sequence: 2, call_mode: :complete, instruction: [instruction],
      conversation: history, token_budget: limit && Phronomy::LlmContextWindow::TokenBudget.new(max_input_tokens: limit),
      previous_manifest: nil, model_config: {model: "test-model"}, metadata: {"caller" => "test"})
  end

  it "reports known and unknown input limits" do
    expect(policy_input.input_token_limit).to eq(100)
    expect(policy_input(limit: nil).input_token_limit).to be_nil
  end

  it "derives a smaller immutable input while retaining every other field" do
    source = policy_input
    derived = source.with_input_token_limit(50)

    expect(derived).not_to equal(source)
    expect(derived).to be_frozen
    expect(source).to be_frozen
    expect(derived.input_token_limit).to eq(50)
    expect(source.input_token_limit).to eq(100)
    expect(derived.to_h.except(:token_budget)).to eq(source.to_h.except(:token_budget))
    expect { derived.instance_variable_set(:@changed, true) }.to raise_error(FrozenError)
  end

  it "allows retaining a known limit" do
    expect(policy_input.with_input_token_limit(100).input_token_limit).to eq(100)
  end

  it "rejects increasing either the original or an already reduced limit" do
    source = policy_input
    expect { source.with_input_token_limit(101) }
      .to raise_error(ArgumentError, /must not exceed/)
    reduced = source.with_input_token_limit(50)
    expect { reduced.with_input_token_limit(51) }
      .to raise_error(ArgumentError, /must not exceed/)
    expect(reduced.with_input_token_limit(25).input_token_limit).to eq(25)
  end

  it "accepts an explicit selection cap when model input capability is unknown" do
    source = policy_input(limit: nil)
    derived = source.with_input_token_limit(50)

    expect(source.input_token_limit).to be_nil
    expect(derived.input_token_limit).to eq(50)
    expect(derived.model_config).to eq(source.model_config)
  end

  it "rejects nonpositive and non-Integer limits without coercion" do
    coercible = Object.new
    def coercible.to_int = 25
    [nil, 0, -1, 1.0, "25", true, coercible].each do |limit|
      expect { policy_input.with_input_token_limit(limit) }
        .to raise_error(ArgumentError, /positive Integer/)
      expect { policy_input(limit: nil).with_input_token_limit(limit) }
        .to raise_error(ArgumentError, /positive Integer/)
    end
  end

  it "reuses DefaultPolicy selection with the smaller budget and intact history groups" do
    source = policy_input
    policy = Phronomy::Context::DefaultPolicy.instance
    ordinary = policy.call(source)
    reserved = policy.call(source.with_input_token_limit(50))

    expect(ordinary.conversation).to eq(source.conversation)
    expect(reserved.conversation).to eq(source.conversation.last(2))
    expect(reserved.instruction).to eq(source.instruction)
    expect(source.conversation.length).to eq(3)
    expect { policy.call(source.with_input_token_limit(5)) }
      .to raise_error(Phronomy::Context::BudgetExceededError)
  end

  it "exposes estimation only as a protected subclass helper" do
    expect(Phronomy::Context::ContextPolicy.protected_instance_methods).to include(:estimate_tokens)
    expect(policy_class.new).not_to respond_to(:estimate_tokens)
  end

  it "matches generated item estimates for text and canonical structured content" do
    values = ["", "plain text", {"z" => [1, "quoted \" and escaped \\", nil], "a" => {"flag" => true}}]
    values.each do |value|
      estimates = policy_class.new.estimates(value)
      expect(estimates.uniq.length).to eq(1)
      expect(estimates.first).to be_a(Integer)
      expect(estimates.first).to be >= 0
    end
    expect(policy_class.new.estimates({"a" => 1, "z" => 2}))
      .to eq(policy_class.new.estimates({"z" => 2, "a" => 1}))
  end

  it "shares the framework estimator and canonical encoding with generated items" do
    estimator = Phronomy::LlmContextWindow::TokenEstimator
    previous = estimator.tokenizer
    observed = []
    estimator.tokenizer = lambda do |text|
      observed << text
      text.bytesize + 7
    end
    content = {"z" => ["quoted \"", "slash \\"], "a" => true}

    estimates = policy_class.new.estimates(content)

    expect(estimates.uniq).to eq([Phronomy::CanonicalJSON.dump(content).bytesize + 7])
    expect(observed).to eq([Phronomy::CanonicalJSON.dump(content)] * 4)
  ensure
    estimator.tokenizer = previous
  end
end
