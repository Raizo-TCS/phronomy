# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe Phronomy::GeneratorVerifier do
  # Bounds a pipeline.invoke call so a regression that causes the Workflow
  # to hang surfaces as a test failure instead of a CI stall.
  def invoke_bounded(pipeline, input, seconds: 3)
    Timeout.timeout(seconds) { pipeline.invoke(input) }
  end

  def stub_agent(output_json, delay: 0, observed: nil)
    output = output_json
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-114", version: 1
      define_method(:invoke) do |_input, config: {}, **_keywords|
        {output: output, messages: []}
      end

      define_method(:invoke_async) do |input, on_event: nil, **_keywords|
        observed << on_event unless observed.nil?
        Phronomy::Runtime.instance.spawn(name: "generator-verifier-stub") do
          sleep(delay) if delay.positive?
          result = invoke(input)
          on_event&.call(
            Phronomy::Agent::StreamEvent.new(
              type: :done,
              payload: result
            )
          )
          result
        rescue => error
          on_event&.call(
            Phronomy::Agent::StreamEvent.new(
              type: :error,
              payload: {error: error}
            )
          )
          raise
        end
      end
    end
  end

  def failing_agent(message)
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-115", version: 1
      define_method(:invoke_async) do |_input, on_event: nil, **_keywords|
        Phronomy::Runtime.instance.spawn(name: "generator-verifier-failure") do
          error = RuntimeError.new(message)
          on_event&.call(
            Phronomy::Agent::StreamEvent.new(
              type: :error,
              payload: {error: error}
            )
          )
          raise error
        end
      end
    end
  end

  let(:good_draft_json) do
    '{"answer":"Full refund within 30 days.","confidence":0.9,' \
      '"citations":[{"source":"refund_policy.md",' \
      '"excerpt":"30-day refund window"}]}'
  end
  let(:low_draft_json) do
    '{"answer":"Maybe 30 days.","confidence":0.3,"citations":[]}'
  end
  let(:approval_json) do
    '{"approved":true,"score":0.85,"feedback":""}'
  end
  let(:rejection_json) do
    '{"approved":false,"score":0.4,' \
      '"feedback":"Missing citation for claim X."}'
  end
  let(:unparseable_json) { "I think it looks fine!" }

  let(:good_draft) { stub_agent(good_draft_json) }
  let(:low_draft) { stub_agent(low_draft_json) }
  let(:approve) { stub_agent(approval_json) }
  let(:reject) { stub_agent(rejection_json) }
  let(:unparseable) { stub_agent(unparseable_json) }

  let(:draft_prompt_builder) do
    ->(input, _feedback) { "Draft: #{input}" }
  end
  let(:review_prompt_builder) do
    ->(input, _draft, _citations) { "Review: #{input}" }
  end

  after do
    Phronomy.reset_runtime!
  rescue
    nil
  end

  def build_pipeline(draft_agent:, review_agent:, **options)
    described_class.new(
      draft_agent: draft_agent,
      review_agent: review_agent,
      draft_prompt_builder: draft_prompt_builder,
      review_prompt_builder: review_prompt_builder,
      **options
    )
  end

  it "maps Agent done events into Workflow transitions" do
    observed_listeners = []
    pipeline = build_pipeline(
      draft_agent: stub_agent(
        good_draft_json,
        observed: observed_listeners
      ),
      review_agent: stub_agent(
        approval_json,
        observed: observed_listeners
      )
    )

    result = invoke_bounded(pipeline, "What is the refund policy?")

    expect(observed_listeners).to all(be_a(Proc))
    expect(result).to be_trusted
    expect(result.output).to include("30 days")
    expect(result.iterations).to eq(1)
  end

  it "does not rely on returning Agent Tasks from Workflow entry actions" do
    pipeline = build_pipeline(
      draft_agent: stub_agent(good_draft_json, delay: 0.01),
      review_agent: stub_agent(approval_json, delay: 0.01)
    )

    expect { invoke_bounded(pipeline, "test") }.not_to raise_error
  end

  it "populates citations and combined confidence" do
    result = invoke_bounded(
      build_pipeline(draft_agent: good_draft, review_agent: approve),
      "test"
    )

    expect(result.citations.first[:source]).to eq("refund_policy.md")
    expect(result.citations.first[:excerpt]).to include("30-day")
    expect(result.confidence).to be_within(0.01).of(0.85)
  end

  it "retries until max_iterations and accumulates feedback" do
    result = invoke_bounded(
      build_pipeline(
        draft_agent: low_draft,
        review_agent: reject,
        confidence_threshold: 0.7,
        max_iterations: 2
      ),
      "test"
    )

    expect(result).not_to be_trusted
    expect(result.iterations).to eq(2)
    expect(result.review_notes.length).to eq(2)
    expect(result.review_notes.first).to include("Missing citation")
  end

  it "passes reviewer feedback into the next draft prompt" do
    feedbacks = []
    builder = ->(_input, feedback) {
      feedbacks << feedback
      "draft prompt"
    }
    pipeline = described_class.new(
      draft_agent: low_draft,
      review_agent: reject,
      draft_prompt_builder: builder,
      review_prompt_builder: review_prompt_builder,
      max_iterations: 2
    )

    invoke_bounded(pipeline, "test")

    expect(feedbacks[0]).to be_nil
    expect(feedbacks[1]).to include("Missing citation")
  end

  it "uses custom result parsers in the Agent event listener" do
    draft_parser_called = false
    review_parser_called = false
    pipeline = build_pipeline(
      draft_agent: stub_agent("raw draft"),
      review_agent: stub_agent("raw review"),
      draft_result_parser: ->(text) {
        draft_parser_called = true
        {answer: "custom: #{text}", confidence: 0.95, citations: []}
      },
      review_result_parser: ->(_text) {
        review_parser_called = true
        {approved: true, score: 0.99, feedback: ""}
      }
    )

    result = invoke_bounded(pipeline, "test")

    expect(draft_parser_called).to be(true)
    expect(review_parser_called).to be(true)
    expect(result.output).to start_with("custom:")
  end

  it "uses safe parser fallbacks for unparseable Agent output" do
    result = invoke_bounded(
      build_pipeline(
        draft_agent: unparseable,
        review_agent: unparseable,
        max_iterations: 1
      ),
      "test"
    )

    expect(result.output).to eq("I think it looks fine!")
    expect(result.confidence).to eq(0.0)
    expect(result).not_to be_trusted
  end

  it "propagates mapped Agent failure through the Workflow" do
    pipeline = build_pipeline(
      draft_agent: failing_agent("draft failed"),
      review_agent: approve
    )

    expect { invoke_bounded(pipeline, "test") }
      .to raise_error(RuntimeError, "draft failed")
  end

  describe "raise_if_untrusted:" do
    it "does not raise by default" do
      pipeline = build_pipeline(
        draft_agent: low_draft,
        review_agent: reject,
        max_iterations: 1
      )
      expect { invoke_bounded(pipeline, "test") }.not_to raise_error
    end

    it "does not raise for a trusted result" do
      pipeline = build_pipeline(
        draft_agent: good_draft,
        review_agent: approve,
        raise_if_untrusted: true
      )
      expect { invoke_bounded(pipeline, "test") }.not_to raise_error
    end

    it "raises LowConfidenceError with the result when untrusted" do
      pipeline = build_pipeline(
        draft_agent: low_draft,
        review_agent: reject,
        max_iterations: 1,
        raise_if_untrusted: true
      )

      expect { invoke_bounded(pipeline, "test") }
        .to raise_error(Phronomy::LowConfidenceError) do |error|
          expect(error.result).to be_a(Phronomy::GeneratorVerifier::Result)
          expect(error.result).not_to be_trusted
        end
    end
  end

  it "caches the compiled Workflow" do
    pipeline = build_pipeline(
      draft_agent: good_draft,
      review_agent: approve
    )

    invoke_bounded(pipeline, "one")
    first = pipeline.send(:compiled_workflow)
    invoke_bounded(pipeline, "two")
    second = pipeline.send(:compiled_workflow)

    expect(second).to equal(first)
  end

  it "exposes trusted? as an alias" do
    result = described_class::Result.new(
      output: "ok",
      confidence: 0.8,
      citations: [],
      iterations: 1,
      review_notes: [],
      trusted: true
    )
    expect(result).to be_trusted
  end
end
