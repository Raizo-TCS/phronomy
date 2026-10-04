# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::LLMAdapter::RubyLLM do
  subject(:adapter) { described_class.new }
  let(:request) { Phronomy::LLMAdapter::Request.new(system: "system", message: "input") }

  it "translates constructor and instruction-setting failures with their original cause" do
    error = RubyLLM::RateLimitError.new("provider unavailable")
    allow(RubyLLM).to receive(:chat).and_raise(error)
    expect { adapter.complete(request) }.to raise_error(Phronomy::LLMAdapter::RateLimitError) { |mapped| expect(mapped.cause).to equal(error) }
    chat = double("chat")
    allow(RubyLLM).to receive(:chat).and_return(chat)
    allow(chat).to receive(:with_instructions).and_raise(error)
    expect { adapter.complete(request) }.to raise_error(Phronomy::LLMAdapter::RateLimitError) { |mapped| expect(mapped.cause).to equal(error) }
  end

  it "preserves cancellation and application callback error identities through streaming" do
    [Phronomy::CancellationError.new("cancelled"), RuntimeError.new("callback"), RubyLLM::RateLimitError.new("callback")].each do |error|
      chat = double("chat", with_instructions: nil, after_message: nil)
      allow(RubyLLM).to receive(:chat).and_return(chat)
      allow(chat).to receive(:ask) { |_message, &block| block.call(Struct.new(:content).new("part")) }
      expect { adapter.stream(request) { raise error } }.to raise_error { |raised| expect(raised).to equal(error) }
    end
  end

  [Object.new, Struct.new(:role, :content).new(:user, "bad"),
    Struct.new(:role, :content, :tool_calls).new(:assistant, nil, :bad)].each do |value|
    it "rejects malformed provider output #{value.class}" do
      allow(RubyLLM).to receive(:chat).and_return(double(:chat, after_message: nil, complete: value))
      expect { adapter.complete(Phronomy::LLMAdapter::Request.new) }.to raise_error(Phronomy::LLMAdapter::InvalidResultError)
    end
  end
end
