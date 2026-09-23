# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent Chat construction and projection contract" do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      model "class-model"
      provider :openai
      temperature 0.4
      max_output_tokens 200
    end
  end
  let(:agent) { agent_class.allocate }
  let(:chat) { double(:chat) }

  it "reads the class configuration only when no explicit model config is supplied" do
    expect(RubyLLM).to receive(:chat).with(model: "class-model", provider: :openai, assume_model_exists: true).ordered.and_return(chat)
    expect(chat).to receive(:with_temperature).with(0.4).ordered
    expect(chat).to receive(:with_max_output_tokens).with(200).ordered
    expect(agent.send(:build_chat)).to equal(chat)
  end

  it "uses the saved model config without consulting current class settings" do
    %i[model provider temperature max_output_tokens].each do |name|
      expect(agent_class).not_to receive(name)
    end
    config = {"model" => "saved", "provider" => "anthropic", "temperature" => 0, "max_output_tokens" => 0}
    expect(RubyLLM).to receive(:chat).with(model: "saved", provider: :anthropic, assume_model_exists: true).ordered.and_return(chat)
    expect(chat).to receive(:with_temperature).with(0).ordered
    expect(chat).to receive(:with_max_output_tokens).with(0).ordered
    expect(agent.send(:build_chat, model_config: config)).to equal(chat)
  end

  [{}, {"model" => false, "provider" => false, "temperature" => false, "max_output_tokens" => false}].each do |config|
    it "does not fall back from an explicit config #{config.inspect}" do
      expect(RubyLLM).to receive(:chat).with(no_args).and_return(chat)
      expect(chat).not_to receive(:with_temperature)
      expect(chat).not_to receive(:with_max_output_tokens)
      expect(agent.send(:build_chat, model_config: config)).to equal(chat)
    end
  end

  it "tolerates a chat without a max-output setter" do
    unsupported = Object.new
    expect(RubyLLM).to receive(:chat).with(model: "saved").and_return(unsupported)
    expect(unsupported).not_to respond_to(:with_max_output_tokens)
    expect(agent.send(:build_chat, model_config: {"model" => "saved", "max_output_tokens" => 10})).to equal(unsupported)
  end

  it "propagates a construction failure without trying configuration setters" do
    error = RuntimeError.new("chat creation failed")
    expect(RubyLLM).to receive(:chat).and_raise(error)
    expect(chat).not_to receive(:with_temperature)
    expect { agent.send(:build_chat) }.to raise_error { |actual| expect(actual).to equal(error) }
  end

  it "stops before the token setter when the temperature setter fails" do
    error = RuntimeError.new("temperature rejected")
    expect(RubyLLM).to receive(:chat).and_return(chat)
    expect(chat).to receive(:with_temperature).and_raise(error)
    expect(chat).not_to receive(:with_max_output_tokens)
    expect { agent.send(:build_chat) }.to raise_error { |actual| expect(actual).to equal(error) }
  end

  it "preserves Anthropic instruction caching and the chat setter return value" do
    content = Object.new
    result = Object.new
    expect(RubyLLM::Providers::Anthropic::Content).to receive(:new).with("system", cache: true).and_return(content)
    expect(chat).to receive(:with_instructions).with(content).and_return(result)
    expect(agent.send(:apply_instructions, chat, "system", cache: true, provider: :anthropic)).to equal(result)
  end

  [[false, "anthropic"], [true, "openai"], [true, nil]].each do |cache, provider|
    it "passes ordinary instructions unchanged with cache=#{cache} provider=#{provider.inspect}" do
      text = Object.new
      expect(RubyLLM::Providers::Anthropic::Content).not_to receive(:new)
      expect(chat).to receive(:with_instructions).with(text).and_return(chat)
      expect(agent.send(:apply_instructions, chat, text, cache: cache, provider: provider)).to equal(chat)
    end
  end

  it "installs instructions, prepared tools and original messages in order through existing hooks" do
    tools = [Object.new, Object.new]
    prepared = [Object.new, Object.new]
    invocation = Object.new
    messages = [Object.new, Object.new]
    existing = Object.new
    destination = [existing]
    projection = Struct.new(:system, :model_config, :tool_classes, :messages).new(
      "saved system", {"provider" => "anthropic", "cache_instructions" => true}, tools, messages
    )
    expect(agent).to receive(:apply_instructions).with(chat, "saved system", cache: true, provider: "anthropic").ordered
    tools.each_with_index do |tool, index|
      expect(agent).to receive(:prepare_tool_class).with(tool, invocation: invocation).ordered.and_return(prepared[index])
      expect(chat).to receive(:with_tool).with(prepared[index]).ordered
    end
    expect(chat).to receive(:messages).twice.ordered.and_return(destination)
    expect(agent.send(:_apply_runtime_projection_to_chat, chat, projection, invocation: invocation)).to equal(chat)
    expect(destination).to eq([existing, *messages])
    expect(destination[1]).to equal(messages[0])
    expect(destination[2]).to equal(messages[1])
  end

  it "leaves instructions alone when the projection has no system segment" do
    projection = Struct.new(:system, :tool_classes, :messages).new(nil, [], [])
    expect(agent).not_to receive(:apply_instructions)
    expect(agent.send(:_apply_runtime_projection_to_chat, chat, projection)).to equal(chat)
  end

  it "stops projection installation at the original preparation error" do
    error = RuntimeError.new("tool preparation failed")
    tools = [Object.new, Object.new]
    projection = Struct.new(:system, :tool_classes, :messages).new(nil, tools, [Object.new])
    expect(agent).to receive(:prepare_tool_class).with(tools[0], invocation: nil).and_raise(error)
    expect(agent).not_to receive(:prepare_tool_class).with(tools[1], invocation: nil)
    expect(chat).not_to receive(:with_tool)
    expect(chat).not_to receive(:messages)
    expect { agent.send(:_apply_runtime_projection_to_chat, chat, projection) }
      .to raise_error { |actual| expect(actual).to equal(error) }
  end
end
