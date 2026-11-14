# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent tool composition" do
  let(:member) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "member-definition", version: 3
    end
  end

  def tool_class(name)
    Class.new(Phronomy::Tool::Base) do
      tool_name name
      description "A composed application tool"
      define_method(:execute) { "done" }
    end
  end

  def compose(definitions = {})
    member.with_tools(definitions, id: "composed-member", version: 7)
  end

  it "creates a separate Agent definition while retaining application behavior" do
    member.define_method(:application_label) { "application behavior" }

    composed = compose

    expect(composed.superclass).to equal(member)
    expect(composed.agent_definition).to eq(id: "composed-member", version: 7)
    expect(member.agent_definition).to eq(id: "member-definition", version: 3)
    expect(composed.allocate.application_label).to eq("application behavior")
  end

  it "does not construct a live Agent while composing its definition" do
    member.define_method(:initialize) { raise "Agent construction must be deferred" }

    expect { compose }.not_to raise_error
  end

  it "captures the member model settings instead of using ordinary subclass defaults" do
    member.model("application-model")
    member.provider(:anthropic)
    member.temperature(0.25)
    member.max_iterations(17)
    member.cache_instructions(false)
    member.max_output_tokens(321)

    composed = compose

    expect(composed.model).to eq("application-model")
    expect(composed.provider).to eq(:anthropic)
    expect(composed.temperature).to eq(0.25)
    expect(composed.max_iterations).to eq(17)
    expect(composed.cache_instructions).to be(false)
    expect(composed.max_output_tokens).to eq(321)
  end

  it "preserves an explicit zero iteration limit and zero temperature" do
    member.max_iterations(0)
    member.temperature(0)

    composed = compose

    expect(composed.max_iterations).to eq(0)
    expect(composed.temperature).to eq(0)
  end

  it "captures the resolved default model when no model was declared on the member" do
    original = Phronomy.configuration.default_model
    begin
      Phronomy.configuration.default_model = "first-default-model"
      composed = compose
      Phronomy.configuration.default_model = "second-default-model"

      expect(member.model).to eq("second-default-model")
      expect(composed.model).to eq("first-default-model")
    ensure
      Phronomy.configuration.default_model = original
    end
  end

  it "preserves application instruction, ContextPolicy and input hook objects" do
    instructions = ->(input) { "Review #{input}" }
    policy = Phronomy::Context::ContextPolicy.new
    hook = ->(_context) {}
    member.instructions(&instructions)
    member.context_policy(policy)
    member.before_llm_input(&hook)

    composed = compose

    expect(composed.instructions).to equal(instructions)
    expect(composed.context_policy).to equal(policy)
    expect(composed.before_llm_input).to equal(hook)
  end

  it "keeps captured settings when the member is configured again later" do
    first_policy = Phronomy::Context::ContextPolicy.new
    first_hook = ->(_context) {}
    member.model("first-model")
    member.provider(:openai)
    member.instructions("First instructions")
    member.context_policy(first_policy)
    member.before_llm_input(&first_hook)
    member.temperature(0.2)
    member.max_iterations(3)
    member.cache_instructions(false)
    member.max_output_tokens(42)
    composed = compose

    member.model("second-model")
    member.provider(:anthropic)
    member.instructions("Second instructions")
    member.context_policy(Phronomy::Context::ContextPolicy.new)
    member.before_llm_input { nil }
    member.temperature(0.8)
    member.max_iterations(9)
    member.cache_instructions(true)
    member.max_output_tokens(84)

    expect(composed.model).to eq("first-model")
    expect(composed.provider).to eq(:openai)
    expect(composed.instructions).to eq("First instructions")
    expect(composed.context_policy).to equal(first_policy)
    expect(composed.before_llm_input).to equal(first_hook)
    expect(composed.temperature).to eq(0.2)
    expect(composed.max_iterations).to eq(3)
    expect(composed.cache_instructions).to be(false)
    expect(composed.max_output_tokens).to eq(42)
  end

  it "keeps absent instructions and provider settings absent after composition" do
    expect(member.instructions).to be_nil
    expect(member.provider).to be_nil
    composed = compose

    member.instructions("Added later")
    member.provider(:openai)

    expect(composed.instructions).to be_nil
    expect(composed.provider).to be_nil
  end

  {
    input_filter: :_class_input_filters,
    output_filter: :_class_output_filters,
    tool_result_filter: :_class_tool_result_filters
  }.each do |registration, reader|
    it "preserves ordered #{registration} objects without sharing the mutable registration list" do
      first = ->(value) { value }
      second = ->(value) { value }
      member.public_send(registration, first)
      member.public_send(registration, second)
      composed = compose
      expect(composed.public_send(reader)).to eq([first, second])
      expect(composed.public_send(reader)).not_to equal(member.public_send(reader))

      composed_only = ->(value) { value }
      member_only = ->(value) { value }
      composed.public_send(registration, composed_only)
      member.public_send(registration, member_only)

      expect(composed.public_send(reader)).to eq([first, second, composed_only])
      expect(member.public_send(reader)).to eq([first, second, member_only])
    end
  end

  it "replaces the Tool set while leaving the original member Tool declarations intact" do
    original = tool_class("original")
    added = tool_class("added")
    member.tools(original => "original_alias")

    composed = compose(added => "sharing_alias")

    expect(composed.tools).to eq([added])
    expect(composed.tool_aliases).to eq(added => "sharing_alias")
    expect(member.tools).to eq([original])
    expect(member.tool_aliases).to eq(original => "original_alias")
  end

  it "clears a member alias when its replacement definition explicitly uses the Tool name" do
    retained = tool_class("lookup")
    member.tools(retained => "member_lookup")

    composed = compose(retained => nil)

    expect(composed.tools).to eq([retained])
    expect(composed.tool_aliases).not_to have_key(retained)
    expect(member.tool_aliases).to eq(retained => "member_lookup")
  end

  it "copies caller Tool declarations and normalizes aliases without mutating the caller" do
    first = tool_class("first")
    second = tool_class("second")
    definitions = {first => :lookup}

    composed = compose(definitions)
    definitions.clear
    definitions[second] = :later

    expect(composed.tools).to eq([first])
    expect(composed.tool_aliases).to eq(first => "lookup")
    expect(definitions).to eq(second => :later)
  end

  it "allows an empty replacement Tool set without retaining obsolete aliases" do
    original = tool_class("original")
    member.tools(original => "old_alias")

    composed = compose

    expect(composed.tools).to eq([])
    expect(composed.tool_aliases).to eq({})
    expect(member.tools).to eq([original])
  end

  [[], nil].each do |definitions|
    it "rejects #{definitions.inspect} instead of treating it as a Tool declaration" do
      expect { compose(definitions) }.to raise_error(ArgumentError, /Hash/)
    end
  end
end
