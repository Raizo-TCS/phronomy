# frozen_string_literal: true

require "spec_helper"

RSpec.describe "LLM backend construction and projection" do
  let(:adapter) { Phronomy::LLMAdapter::RubyLLM.new }
  let(:messages) { [] }
  let(:response) { RubyLLM::Message.new(role: :assistant, content: "done") }
  let(:chat) { double(:chat, messages: messages, after_message: nil, complete: response) }

  it "renders only the saved request configuration and never consults Agent settings" do
    request = Phronomy::LLMAdapter::Request.new(model_config: {
      "model" => "saved", "provider" => "anthropic", "temperature" => 0,
      "max_output_tokens" => 200, "cache_instructions" => true
    }, system: "saved system")
    expect(RubyLLM).to receive(:chat).with(model: "saved", provider: :anthropic, assume_model_exists: true).ordered.and_return(chat)
    expect(chat).to receive(:with_temperature).with(0).ordered
    expect(chat).to receive(:with_max_output_tokens).with(200).ordered
    expect(chat).to receive(:with_instructions).with("saved system", cache_until_here: true).ordered
    expect(adapter.complete(request).content).to eq("done")
  end

  it "does not add absent configuration values" do
    expect(RubyLLM).to receive(:chat).with(no_args).and_return(chat)
    expect(chat).not_to receive(:with_temperature)
    expect(chat).not_to receive(:with_max_output_tokens)
    expect(chat).not_to receive(:with_instructions)
    adapter.complete(Phronomy::LLMAdapter::Request.new)
  end

  it "stops construction at the original setter error" do
    error = RuntimeError.new("temperature rejected")
    allow(RubyLLM).to receive(:chat).and_return(chat)
    expect(chat).to receive(:with_temperature).and_raise(error)
    expect(chat).not_to receive(:with_max_output_tokens)
    expect(chat).not_to receive(:complete)
    request = Phronomy::LLMAdapter::Request.new(model_config: {"temperature" => 0.2, "max_output_tokens" => 20})
    expect { adapter.complete(request) }.to raise_error { |actual| expect(actual).to equal(error) }
  end

  it "renders inert definitions and saved Tool history inside the backend" do
    call = Phronomy::Tool::CallRequest.new(id: "one", name: "lookup", arguments: {"n" => 2}, metadata: {"thought_signature" => "opaque"})
    request = Phronomy::LLMAdapter::Request.new(tools: [{
      "name" => "lookup", "description" => "Lookup", "parameters_schema" => {"type" => "object"}
    }], messages: [
      Phronomy::LLMAdapter::Message.new(role: :assistant, tool_calls: [call]),
      Phronomy::LLMAdapter::Message.new(role: :tool, content: {"value" => 2}, tool_call_id: "one")
    ])
    allow(RubyLLM).to receive(:chat).and_return(chat)
    expect(chat).to receive(:with_tools) do |declaration|
      expect(declaration.tool_name).to eq("lookup")
      expect { declaration.new.execute }.to raise_error(Phronomy::LLMAdapter::InvalidResultError, /declaration-only/)
    end
    adapter.complete(request)
    expect(messages).to all(be_a(RubyLLM::Message))
    expect(messages.first.tool_calls.fetch("one").thought_signature).to eq("opaque")
    expect(messages.last.content).to eq('{"value":2}')
    expect(request.messages.first.content).to be_nil
  end

  it "uses ask for a new message and typed stream chunks for notifications" do
    allow(RubyLLM).to receive(:chat).and_return(chat)
    expect(chat).to receive(:ask).with("ping") do |_, &sink|
      sink.call(Struct.new(:content).new("part"))
      response
    end
    chunks = []
    value = adapter.stream(Phronomy::LLMAdapter::Request.new(message: "ping")) { |chunk| chunks << chunk }
    expect(value).to be_a(Phronomy::LLMAdapter::Response)
    expect(chunks.map(&:content)).to eq(["part"])
    expect(chunks).to all(be_frozen)
  end
end
