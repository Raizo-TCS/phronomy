# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::LLMAdapter::RubyLLM do
  subject(:adapter) { described_class.new }

  it "translates constructor and instruction-setting failures with their original cause" do
    error = RubyLLM::RateLimitError.new("provider unavailable")
    allow(RubyLLM).to receive(:chat).and_raise(error)
    expect { adapter.build_chat({}) }.to raise_error(Phronomy::RateLimitError) { |mapped| expect(mapped.cause).to equal(error) }
    chat = double("chat")
    allow(chat).to receive(:with_instructions).and_raise(error)
    expect { adapter.configure_chat(chat, system: "system", cache: false, tools: [], messages: []) }
      .to raise_error(Phronomy::RateLimitError) { |mapped| expect(mapped.cause).to equal(error) }
  end

  it "preserves cancellation and application callback error identities through streaming" do
    [Phronomy::CancellationError.new("cancelled"), RuntimeError.new("callback")].each do |error|
      chat = double("chat")
      allow(chat).to receive(:ask) { |_message, &block| block.call(:chunk) }
      expect { adapter.stream(chat, "input") { raise error } }
        .to raise_error { |raised| expect(raised).to equal(error) }
    end
  end
end
