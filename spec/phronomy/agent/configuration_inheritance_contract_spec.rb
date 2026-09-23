# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent configuration inheritance contract" do
  let(:parent) { Class.new(Phronomy::Agent::Base) }
  let(:child) { Class.new(parent) }

  it "uses the global model rather than the parent and observes later global changes" do
    original = Phronomy.configuration.default_model
    begin
      parent.model "parent-model"
      Phronomy.configuration.default_model = "global-first"
      expect(child.model).to eq("global-first")
      Phronomy.configuration.default_model = "global-second"
      expect(child.model).to eq("global-second")
      child.model "child-model"
      expect(child.model).to eq("child-model")
      expect(parent.model).to eq("parent-model")
    ensure
      Phronomy.configuration.default_model = original
    end
  end

  {instructions: "instructions", provider: :openai}.each do |setting, value|
    it "reads #{setting} dynamically from the parent until the child overrides it" do
      parent.public_send(setting, value)
      expect(child.public_send(setting)).to eq(value)
      parent.public_send(setting, "changed")
      expect(child.public_send(setting)).to eq("changed")
      child.public_send(setting, "own")
      expect(child.public_send(setting)).to eq("own")
      expect(parent.public_send(setting)).to eq("changed")
      child.public_send(setting, nil)
      expect(child.public_send(setting)).to eq("own")
    end
  end

  it "inherits the same instructions callback object without cloning it" do
    callback = ->(input) { input.to_s }
    parent.instructions(&callback)
    expect(child.instructions).to equal(callback)
  end

  it "inherits ContextPolicy by identity and lets a child replace it" do
    first = Phronomy::Agent::ContextPolicy.new
    second = Phronomy::Agent::ContextPolicy.new
    expect(child.context_policy).to equal(Phronomy::Agent::ContextPolicies::Default.instance)
    parent.context_policy(first)
    expect(child.context_policy).to equal(first)
    child.context_policy(second)
    expect(child.context_policy).to equal(second)
    expect(parent.context_policy).to equal(first)
    expect { child.context_policy(nil) }.to raise_error(ArgumentError)
  end

  {temperature: 0.7, cache_instructions: true, max_output_tokens: 321}.each do |setting, value|
    it "does not inherit #{setting}" do
      parent.public_send(setting, value)
      expect(child.public_send(setting)).to be_nil
      child.public_send(setting, value)
      expect(child.public_send(setting)).to eq(value)
      expect(parent.public_send(setting)).to eq(value)
    end
  end

  it "uses ten iterations when the child has no own setting and accepts zero" do
    parent.max_iterations(27)
    expect(child.max_iterations).to eq(10)
    child.max_iterations(0)
    expect(child.max_iterations).to eq(0)
    expect(parent.max_iterations).to eq(27)
  end

  it "keeps nil as a reader, false as a cache value and numeric coercion for token limits" do
    child.temperature(0)
    expect(child.temperature(nil)).to eq(0)
    child.cache_instructions(false)
    expect(child.cache_instructions(nil)).to be(false)
    child.max_output_tokens("12")
    expect(child.max_output_tokens(nil)).to eq(12)
  end

  it "inherits the tools array by reference until an own declaration replaces it" do
    first = Class.new
    second = Class.new
    parent.tools(first => nil)
    expect(child.tools).to equal(parent.tools)
    parent.tools(second => nil)
    expect(child.tools).to eq([second])
    child.tools({})
    expect(child.tools).to eq([])
    expect(parent.tools).to eq([second])
  end

  it "merges aliases separately, so a nil alias or an empty tool set does not clear inherited aliases" do
    tool = Class.new
    parent.tools(tool => :parent_alias)
    child.tools(tool => nil)
    expect(child.tool_aliases[tool]).to eq("parent_alias")
    child.tools({})
    expect(child.tool_aliases[tool]).to eq("parent_alias")
    child.tools(tool => :child_alias)
    expect(child.tool_aliases[tool]).to eq("child_alias")
    expect(parent.tool_aliases[tool]).to eq("parent_alias")
  end

  it "requires a separate definition identity for each subclass" do
    parent.agent_definition(id: "parent", version: 1)
    expect { child.agent_definition }.to raise_error(Phronomy::ConfigurationError)
    child.agent_definition(id: "child", version: 2)
    expect(child.agent_definition).to eq(id: "child", version: 2)
    expect(parent.agent_definition).to eq(id: "parent", version: 1)
  end

  it "does not inherit class filters or the before_llm_input callback" do
    callback = ->(_input) {}
    filter = Object.new
    parent.input_filter(filter)
    parent.output_filter(filter)
    parent.tool_result_filter(filter)
    parent.before_llm_input(&callback)
    expect(child._class_input_filters).to eq([])
    expect(child._class_output_filters).to eq([])
    expect(child._class_tool_result_filters).to eq([])
    expect(child.before_llm_input).to be_nil
    expect(child._before_llm_input).to be_nil
  end
end
