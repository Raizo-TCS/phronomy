# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Testing::Eval::Scorer::LlmJudge do
  def score(judge)
    judge.score(actual: "actual", expected: "expected", input: "question")
  end

  it "executes the provider on a worker and parses the result" do
    caller_thread = Thread.current
    chat = double("chat")
    allow(RubyLLM).to receive(:chat).with(model: "test", provider: nil, assume_model_exists: false).and_return(chat)
    allow(chat).to receive(:ask) do |prompt|
      expect(Thread.current).not_to equal(caller_thread)
      expect(prompt).to include("question", "expected", "actual")
      Struct.new(:content).new("0.75")
    end
    expect(score(described_class.new(model: "test"))).to eq(0.75)
  end

  [false, true].each do |raise_on_error|
    it "preserves the provider failure policy when raise_on_error is #{raise_on_error}" do
      error = RuntimeError.new("provider failed")
      allow(RubyLLM).to receive(:chat).and_raise(error)
      judge = described_class.new(model: "test", raise_on_error: raise_on_error)
      if raise_on_error
        expect { score(judge) }.to raise_error { |caught| expect(caught).to equal(error) }
      else
        expect(judge).to receive(:warn).with("[LlmJudge] Scoring failed: provider failed")
        expect(score(judge)).to eq(0.0)
      end
    end

    it "preserves the failed admission policy when raise_on_error is #{raise_on_error}" do
      error = Phronomy::BackpressureError.new("queue full")
      allow(Phronomy::Runtime.instance.offload).to receive(:submit).and_raise(error)
      expect(RubyLLM).not_to receive(:chat)
      judge = described_class.new(model: "test", raise_on_error: raise_on_error)
      if raise_on_error
        expect { score(judge) }.to raise_error { |caught| expect(caught).to equal(error) }
      else
        expect(judge).to receive(:warn).with("[LlmJudge] Scoring failed: queue full")
        expect(score(judge)).to eq(0.0)
      end
    end
  end
end
