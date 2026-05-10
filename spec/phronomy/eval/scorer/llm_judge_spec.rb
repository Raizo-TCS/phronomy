# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Eval::Scorer::LlmJudge do
  subject(:judge) { described_class.new(model: "test-model") }

  # Stub the RubyLLM chat interface so no real HTTP call is made.
  def stub_llm_response(text)
    response = instance_double(RubyLLM::Message, content: text)
    chat = instance_double(RubyLLM::Chat)
    allow(chat).to receive(:ask).and_return(response)
    allow(RubyLLM).to receive(:chat).with(model: "test-model").and_return(chat)
  end

  describe "#score" do
    it "parses a floating-point reply" do
      stub_llm_response("0.8")
      expect(judge.score(actual: "Paris", expected: "Paris", input: "Capital?")).to eq(0.8)
    end

    it "parses a reply with surrounding text" do
      stub_llm_response("Score: 0.9 out of 1.0")
      expect(judge.score(actual: "a", expected: "a")).to eq(0.9)
    end

    it "clamps values above 1.0 to 1.0" do
      stub_llm_response("1.5")
      expect(judge.score(actual: "a", expected: "a")).to eq(1.0)
    end

    it "clamps negative values to 0.0" do
      stub_llm_response("-0.3")
      expect(judge.score(actual: "a", expected: "a")).to eq(0.0)
    end

    it "returns 0.0 when the LLM raises an error" do
      allow(RubyLLM).to receive(:chat).and_raise(RuntimeError, "connection refused")
      expect(judge.score(actual: "a", expected: "a")).to eq(0.0)
    end

    it "returns 0.0 when reply contains no parseable number" do
      stub_llm_response("I cannot evaluate this.")
      # scan returns empty array → .first.to_f == 0.0
      expect(judge.score(actual: "a", expected: "a")).to eq(0.0)
    end

    context "when raise_on_error: true" do
      subject(:strict_judge) { described_class.new(model: "test-model", raise_on_error: true) }

      it "re-raises the exception instead of returning 0.0" do
        allow(RubyLLM).to receive(:chat).and_raise(RuntimeError, "network error")
        expect { strict_judge.score(actual: "a", expected: "a") }
          .to raise_error(RuntimeError, "network error")
      end
    end

    context "when raise_on_error: false (default)" do
      it "returns 0.0 on error and does not raise" do
        allow(RubyLLM).to receive(:chat).and_raise(RuntimeError, "timeout")
        expect { judge.score(actual: "a", expected: "a") }.not_to raise_error
        expect(judge.score(actual: "a", expected: "a")).to eq(0.0)
      end
    end
  end

  describe "custom prompt template" do
    it "uses the supplied template" do
      custom_tmpl = "Rate: %<actual>s vs %<expected>s. Input: %<input>s."
      custom_judge = described_class.new(model: "test-model", prompt_template: custom_tmpl)

      chat = instance_double(RubyLLM::Chat)
      response = instance_double(RubyLLM::Message, content: "1.0")
      expect(chat).to receive(:ask).with("Rate: Paris vs Paris. Input: q.").and_return(response)
      allow(RubyLLM).to receive(:chat).with(model: "test-model").and_return(chat)

      custom_judge.score(actual: "Paris", expected: "Paris", input: "q")
    end
  end
end
