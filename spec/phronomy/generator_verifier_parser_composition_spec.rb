# frozen_string_literal: true

require "spec_helper"

RSpec.describe "GeneratorVerifier default parser composition" do
  let(:pipeline) do
    Phronomy::GeneratorVerifier.new(
      draft_agent: Class.new, review_agent: Class.new,
      draft_prompt_builder: ->(*) {}, review_prompt_builder: ->(*) {}
    )
  end

  it "selects JsonParser at boot but creates it lazily once per pipeline" do
    parser = Phronomy::OutputParser::JsonParser.new
    expect(Phronomy::OutputParser::JsonParser).to receive(:new).once.and_return(parser)
    subject = pipeline
    expect(subject.send(:default_parse_draft, '{"answer":"first"}')).to eq(answer: "first")
    expect(subject.send(:default_parse_review, '{"approved":true}')).to eq(approved: true)
  end

  it "uses the supplied parser operation and keeps domain-specific fallbacks" do
    parser = double("parser")
    allow(Phronomy::GeneratorVerifier::DefaultParser).to receive(:build).and_return(parser)
    error = Phronomy::ParseError.new("invalid")
    allow(parser).to receive(:parse).and_raise(error)
    expect(pipeline.send(:default_parse_draft, "draft")).to eq(answer: "draft", confidence: 0.0, citations: [])
    expect(pipeline.send(:default_parse_review, "review")).to eq(approved: false, score: 0.0, feedback: "Review output could not be parsed: review")
  end

  it "does not construct a default parser when both parser callables are supplied" do
    expect(Phronomy::GeneratorVerifier::DefaultParser).not_to receive(:build)
    subject = Phronomy::GeneratorVerifier.new(
      draft_agent: Class.new, review_agent: Class.new,
      draft_prompt_builder: ->(*) {}, review_prompt_builder: ->(*) {},
      draft_result_parser: ->(text) { text }, review_result_parser: ->(text) { text }
    )
    expect(subject.instance_variable_get(:@draft_result_parser).call("draft")).to eq("draft")
    expect(subject.instance_variable_get(:@review_result_parser).call("review")).to eq("review")
  end
end
