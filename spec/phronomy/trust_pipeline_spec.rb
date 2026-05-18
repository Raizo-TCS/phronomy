# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::TrustPipeline do
  # Suppress the deprecation warning emitted by TrustPipeline.new so that
  # these backward-compatibility tests do not pollute the test output.
  before { allow_any_instance_of(described_class).to receive(:warn) }

  # Helper: stub agent class that bypasses real LLM invocation.
  def stub_agent(output_json)
    Class.new(Phronomy::Agent::Base) do
      define_method(:invoke) do |_input, config: {}|
        {output: output_json, messages: []}
      end
    end
  end

  let(:good_draft_json) do
    '{"answer":"Full refund within 30 days.","confidence":0.9,' \
      '"citations":[{"source":"refund_policy.md","excerpt":"30-day refund window"}]}'
  end
  let(:low_draft_json) do
    '{"answer":"Maybe 30 days.","confidence":0.3,"citations":[]}'
  end

  let(:approval_json) { '{"approved":true,"score":0.85,"feedback":""}' }
  let(:rejection_json) { '{"approved":false,"score":0.4,"feedback":"Missing citation for claim X."}' }

  let(:good_draft) { stub_agent(good_draft_json) }
  let(:low_draft) { stub_agent(low_draft_json) }
  let(:approve) { stub_agent(approval_json) }
  let(:reject) { stub_agent(rejection_json) }
  let(:unparseable) { stub_agent("I think it looks fine!") }

  describe "#invoke — approved on first attempt" do
    subject(:pipeline) do
      described_class.new(
        draft_agent: good_draft,
        review_agent: approve,
        confidence_threshold: 0.7,
        max_iterations: 3
      )
    end

    let(:result) { pipeline.invoke("What is the refund policy?") }

    it "returns a trusted result" do
      expect(result).to be_trusted
    end

    it "includes the answer in output" do
      expect(result.output).to include("30 days")
    end

    it "populates citations with source and excerpt" do
      expect(result.citations).not_to be_empty
      expect(result.citations.first[:source]).to eq("refund_policy.md")
      expect(result.citations.first[:excerpt]).to include("30-day")
    end

    it "reports 1 iteration" do
      expect(result.iterations).to eq(1)
    end

    it "sets confidence to the minimum of self and review scores" do
      # self_score=0.9, review_score=0.85 → min=0.85
      expect(result.confidence).to be_within(0.01).of(0.85)
    end
  end

  describe "#invoke — rejected until max_iterations" do
    subject(:pipeline) do
      described_class.new(
        draft_agent: low_draft,
        review_agent: reject,
        confidence_threshold: 0.7,
        max_iterations: 2
      )
    end

    let(:result) { pipeline.invoke("What is the refund policy?") }

    it "is not trusted" do
      expect(result).not_to be_trusted
    end

    it "stops after max_iterations cycles" do
      expect(result.iterations).to eq(2)
    end

    it "accumulates reviewer feedback in review_notes" do
      expect(result.review_notes.length).to eq(2)
      expect(result.review_notes.first).to include("Missing citation")
    end
  end

  describe "#invoke — unparseable review output" do
    subject(:pipeline) do
      described_class.new(
        draft_agent: good_draft,
        review_agent: unparseable,
        confidence_threshold: 0.7,
        max_iterations: 1
      )
    end

    it "does not raise" do
      expect { pipeline.invoke("test") }.not_to raise_error
    end

    it "returns untrusted result (review score defaults to 0.0)" do
      result = pipeline.invoke("test")
      # self_score=0.9, review_score=0.0 → min=0.0 < threshold
      expect(result).not_to be_trusted
    end
  end

  describe "#invoke — unparseable draft output" do
    subject(:pipeline) do
      described_class.new(
        draft_agent: unparseable,
        review_agent: approve,
        confidence_threshold: 0.7,
        max_iterations: 1
      )
    end

    let(:result) { pipeline.invoke("test") }

    it "uses the raw text as output" do
      expect(result.output).to eq("I think it looks fine!")
    end

    it "reports self-confidence of 0.0" do
      # min(0.0, 0.85) = 0.0
      expect(result.confidence).to eq(0.0)
    end
  end

  describe "compiled_graph caching" do
    subject(:pipeline) do
      described_class.new(
        draft_agent: good_draft,
        review_agent: approve,
        confidence_threshold: 0.7,
        max_iterations: 3
      )
    end

    it "returns the same compiled graph object on repeated invocations" do
      pipeline.invoke("question one")
      graph_first = pipeline.send(:compiled_graph)
      pipeline.invoke("question two")
      graph_second = pipeline.send(:compiled_graph)
      expect(graph_first).to equal(graph_second)
    end
  end

  describe "input_delimiter:" do
    def capture_prompt(delimiter)
      received = []
      capturing_draft = Class.new(Phronomy::Agent::Base) do
        define_method(:invoke) do |input, config: {}|
          received << input
          {output: '{"answer":"ok","confidence":0.9,"citations":[]}', messages: []}
        end
      end
      pipeline = described_class.new(
        draft_agent: capturing_draft,
        review_agent: stub_agent('{"approved":true,"score":0.9,"feedback":""}'),
        confidence_threshold: 0.7,
        max_iterations: 1,
        input_delimiter: delimiter
      )
      pipeline.invoke("What is the refund policy?")
      received.first
    end

    context "when input_delimiter is nil (default)" do
      it "embeds user input without any wrapper" do
        prompt = capture_prompt(nil)
        expect(prompt).to include("Question: What is the refund policy?")
        expect(prompt).not_to match(/<user_input>|===/)
      end
    end

    context "when input_delimiter is XML-style tags" do
      it "wraps user input in the specified tags in the draft prompt" do
        prompt = capture_prompt(["<user_input>", "</user_input>"])
        expect(prompt).to include("<user_input>\nWhat is the refund policy?\n</user_input>")
      end
    end

    context "when input_delimiter uses custom separator strings" do
      it "wraps user input with the custom strings" do
        prompt = capture_prompt(["=== user input start ===", "=== user input end ==="])
        expect(prompt).to include("=== user input start ===\nWhat is the refund policy?\n=== user input end ===")
      end
    end
  end

  describe "Result" do
    it "exposes trusted? as an alias for trusted" do
      r = Phronomy::TrustPipeline::Result.new(
        output: "ok", confidence: 0.8, citations: [],
        iterations: 1, review_notes: [], trusted: true
      )
      expect(r.trusted?).to be true
    end

    it "sets trusted? false when trusted: false" do
      r = Phronomy::TrustPipeline::Result.new(
        output: "ok", confidence: 0.3, citations: [],
        iterations: 2, review_notes: [], trusted: false
      )
      expect(r.trusted?).to be false
    end
  end

  describe "deprecation" do
    it "emits a deprecation warning when instantiated" do
      expect_any_instance_of(described_class).to receive(:warn)
        .with(/deprecated/i)
      described_class.new(
        draft_agent: stub_agent(good_draft_json),
        review_agent: stub_agent(approval_json)
      )
    end

    it "is a subclass of Phronomy::GeneratorVerifier" do
      expect(described_class.ancestors).to include(Phronomy::GeneratorVerifier)
    end
  end
end
