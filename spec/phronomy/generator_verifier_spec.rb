# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::GeneratorVerifier do
  # Stub agent that returns a fixed JSON payload without calling a real LLM.
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
  let(:low_draft_json) { '{"answer":"Maybe 30 days.","confidence":0.3,"citations":[]}' }
  let(:approval_json) { '{"approved":true,"score":0.85,"feedback":""}' }
  let(:rejection_json) { '{"approved":false,"score":0.4,"feedback":"Missing citation for claim X."}' }
  let(:unparseable_json) { "I think it looks fine!" }

  let(:good_draft) { stub_agent(good_draft_json) }
  let(:low_draft) { stub_agent(low_draft_json) }
  let(:approve) { stub_agent(approval_json) }
  let(:reject) { stub_agent(rejection_json) }
  let(:unparseable) { stub_agent(unparseable_json) }

  # Default prompt builders that produce JSON-compatible output the default parsers understand.
  let(:draft_prompt_builder) { ->(input, _feedback) { "Draft: #{input}" } }
  let(:review_prompt_builder) { ->(input, _draft, _citations) { "Review: #{input}" } }

  def build_pipeline(draft_agent:, review_agent:, **opts)
    described_class.new(
      draft_agent: draft_agent,
      review_agent: review_agent,
      draft_prompt_builder: draft_prompt_builder,
      review_prompt_builder: review_prompt_builder,
      **opts
    )
  end

  describe "#invoke — approved on first attempt" do
    subject(:pipeline) do
      build_pipeline(draft_agent: good_draft, review_agent: approve,
        confidence_threshold: 0.7, max_iterations: 3)
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

    it "sets confidence to min(self_score, review_score)" do
      # self_score=0.9, review_score=0.85 → min=0.85
      expect(result.confidence).to be_within(0.01).of(0.85)
    end
  end

  describe "#invoke — rejected until max_iterations" do
    subject(:pipeline) do
      build_pipeline(draft_agent: low_draft, review_agent: reject,
        confidence_threshold: 0.7, max_iterations: 2)
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

  describe "#invoke — custom draft_result_parser" do
    it "uses the caller-supplied parser instead of the default JSON parser" do
      custom_parser_called = false
      custom_parser = ->(text) {
        custom_parser_called = true
        {answer: "custom: #{text}", confidence: 0.95, citations: []}
      }

      pipeline = build_pipeline(
        draft_agent: stub_agent("raw output"),
        review_agent: approve,
        draft_result_parser: custom_parser
      )
      result = pipeline.invoke("test")

      expect(custom_parser_called).to be true
      expect(result.output).to start_with("custom:")
    end
  end

  describe "#invoke — custom review_result_parser" do
    it "uses the caller-supplied parser instead of the default JSON parser" do
      custom_parser_called = false
      custom_parser = ->(text) {
        custom_parser_called = true
        {approved: true, score: 0.99, feedback: ""}
      }

      pipeline = build_pipeline(
        draft_agent: good_draft,
        review_agent: stub_agent("not json"),
        review_result_parser: custom_parser
      )
      result = pipeline.invoke("test")

      expect(custom_parser_called).to be true
      expect(result).to be_trusted
    end
  end

  describe "#invoke — unparseable review output (default parser fallback)" do
    subject(:pipeline) do
      build_pipeline(draft_agent: good_draft, review_agent: unparseable,
        confidence_threshold: 0.7, max_iterations: 1)
    end

    it "does not raise" do
      expect { pipeline.invoke("test") }.not_to raise_error
    end

    it "returns an untrusted result (review score defaults to 0.0)" do
      result = pipeline.invoke("test")
      expect(result).not_to be_trusted
    end
  end

  describe "#invoke — unparseable draft output (default parser fallback)" do
    subject(:pipeline) do
      build_pipeline(draft_agent: unparseable, review_agent: approve,
        confidence_threshold: 0.7, max_iterations: 1)
    end

    let(:result) { pipeline.invoke("test") }

    it "uses the raw text as output" do
      expect(result.output).to eq("I think it looks fine!")
    end

    it "reports self-confidence of 0.0" do
      expect(result.confidence).to eq(0.0)
    end
  end

  describe "raise_if_untrusted:" do
    context "when false (default)" do
      it "does not raise even when confidence is below threshold" do
        pipeline = build_pipeline(draft_agent: low_draft, review_agent: reject,
          confidence_threshold: 0.7, max_iterations: 1)
        expect { pipeline.invoke("test") }.not_to raise_error
      end
    end

    context "when true and result is trusted" do
      it "does not raise" do
        pipeline = build_pipeline(draft_agent: good_draft, review_agent: approve,
          raise_if_untrusted: true)
        expect { pipeline.invoke("test") }.not_to raise_error
      end
    end

    context "when true and result is untrusted" do
      subject(:pipeline) do
        build_pipeline(draft_agent: low_draft, review_agent: reject,
          confidence_threshold: 0.7, max_iterations: 1,
          raise_if_untrusted: true)
      end

      it "raises LowConfidenceError" do
        expect { pipeline.invoke("test") }.to raise_error(Phronomy::LowConfidenceError)
      end

      it "attaches the Result to the error" do
        pipeline.invoke("test")
      rescue Phronomy::LowConfidenceError => e
        expect(e.result).to be_a(Phronomy::GeneratorVerifier::Result)
        expect(e.result).not_to be_trusted
        expect(e.message).to match(/confidence .* below the required threshold/i)
      end
    end
  end

  describe "compiled_graph caching" do
    subject(:pipeline) do
      build_pipeline(draft_agent: good_draft, review_agent: approve)
    end

    it "returns the same compiled graph object on repeated invocations" do
      pipeline.invoke("question one")
      graph_first = pipeline.send(:compiled_graph)
      pipeline.invoke("question two")
      graph_second = pipeline.send(:compiled_graph)
      expect(graph_first).to equal(graph_second)
    end
  end

  describe "draft_prompt_builder" do
    it "is called with (input, feedback) and its return value is sent to the draft agent" do
      received_args = []
      capturing_builder = ->(input, feedback) {
        received_args << [input, feedback]
        '{"answer":"ok","confidence":0.9,"citations":[]}'
      }

      capturing_agent = Class.new(Phronomy::Agent::Base) do
        define_method(:invoke) do |prompt, config: {}|
          {output: prompt, messages: []}
        end
      end

      pipeline = described_class.new(
        draft_agent: capturing_agent,
        review_agent: approve,
        draft_prompt_builder: capturing_builder,
        review_prompt_builder: review_prompt_builder
      )
      pipeline.invoke("my question")

      expect(received_args.first[0]).to eq("my question")
    end

    it "receives the reviewer's feedback on the second iteration" do
      received_feedbacks = []
      capturing_builder = ->(input, feedback) {
        received_feedbacks << feedback
        '{"answer":"ok","confidence":0.9,"citations":[]}'
      }

      pipeline = described_class.new(
        draft_agent: stub_agent('{"answer":"draft","confidence":0.3,"citations":[]}'),
        review_agent: reject,
        draft_prompt_builder: capturing_builder,
        review_prompt_builder: review_prompt_builder,
        max_iterations: 2
      )
      pipeline.invoke("test")

      # First call: nil feedback; second call: rejection feedback
      expect(received_feedbacks[0]).to be_nil
      expect(received_feedbacks[1]).to include("Missing citation")
    end
  end

  describe "Result struct" do
    it "exposes trusted? as an alias for trusted" do
      r = Phronomy::GeneratorVerifier::Result.new(
        output: "ok", confidence: 0.8, citations: [],
        iterations: 1, review_notes: [], trusted: true
      )
      expect(r.trusted?).to be true
    end

    it "sets trusted? false when trusted: false" do
      r = Phronomy::GeneratorVerifier::Result.new(
        output: "ok", confidence: 0.3, citations: [],
        iterations: 2, review_notes: [], trusted: false
      )
      expect(r.trusted?).to be false
    end
  end
end
