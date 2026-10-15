# frozen_string_literal: true

require "spec_helper"

RSpec.describe "GeneratorVerifier structured output" do
  let(:agent_class) { Class.new(Phronomy::Agent::Base) { agent_definition id: "generation-structured", version: 1 } }
  let(:requests) { [] }
  let(:responses) { [] }

  before do
    queue, captured = responses, requests
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |request, cancellation_token:|
        captured << request
        result = queue.shift || raise("unexpected LLM replay")
        raise result if result.is_a?(Exception)
        Phronomy::LLMAdapter::Response.new(content: result, finish_reason: :stop)
      end
    end.new
    Phronomy.configure { |config| config.llm_adapter = adapter }
  end

  def pipeline(**options, &block)
    Phronomy::GeneratorVerifier.open(draft_agent: agent_class, review_agent: agent_class,
      draft_prompt_builder: ->(input, feedback) { "#{input} #{feedback}" },
      review_prompt_builder: ->(_input, draft, _citations) { draft }, **options, &block)
  end

  it "awaits its direct Task and accepts valid zero scores with a zero threshold" do
    responses.concat(['{"answer":"ok","confidence":0,"citations":[]}', '{"approved":true,"score":0,"feedback":""}'])
    result = pipeline(confidence_threshold: 0) { |p| p.invoke_async("question") }
    expect(result).to be_accepted
    expect(result.failure).to be_nil
    expect(requests.length).to eq(2)
    expect(requests.map { |r| r.response_schema["required"] }).to eq([%w[answer confidence citations], %w[approved score feedback]])
  end

  it "never accepts an invalid draft at threshold zero or calls review" do
    responses << "not JSON"
    result = pipeline(confidence_threshold: 0) { |p| p.invoke("question") }
    expect(result.termination_reason).to eq("output_failed")
    expect(result.interrupted_phase).to eq("draft")
    expect(result.output).to be_nil
    expect(result.confidence).to be_nil
    expect(result.review_approved).to be_nil
    expect(result.iterations).to eq(0)
    expect(result.failure["reason"]).to eq("invalid_json")
    expect(requests.length).to eq(1)
    restored = Phronomy::GeneratorVerifier::Result.from_h(JSON.parse(JSON.generate(result.to_h)))
    expect(restored).to eq(result)
    expect(restored.hash).to eq(result.hash)
    expect(restored.failure).to be_frozen
  end

  it "retains a valid draft when review output fails and exposes the original cause on request" do
    responses.concat(['{"answer":"ok","confidence":0.9,"citations":[]}', '{"approved":"true","score":1,"feedback":""}'])
    expect { pipeline(raise_if_unaccepted: true) { |p| p.invoke("q") } }
      .to raise_error(Phronomy::GeneratorVerifier::UnacceptedResultError) { |error|
        expect(error.result.output).to eq("ok")
        expect(error.result.interrupted_phase).to eq("review")
        expect(error.cause).to be_a(Phronomy::Agent::OutputError)
      }
  end

  it "does not reuse an old draft when a later draft fails" do
    responses.concat(['{"answer":"old","confidence":0.5,"citations":[]}',
      '{"approved":false,"score":0.5,"feedback":"try again"}', "invalid"])
    result = pipeline { |p| p.invoke("q") }
    expect(result.termination_reason).to eq("output_failed")
    expect(result.iterations).to eq(1)
    expect(result.output).to be_nil
    expect(result.citations).to eq([])
    expect(result.review_notes).to eq(["try again"])
  end

  it "supports application citation shapes without replacing the evaluation protocol" do
    responses.concat(['{"answer":"ok","confidence":0.9,"citations":[{"page":2}]}', '{"approved":true,"score":0.9,"feedback":""}'])
    result = pipeline(citation_schema: {type: "object", properties: {page: {type: "integer"}}, required: ["page"], additionalProperties: false}) { |p| p.invoke("q") }
    expect(result).to be_accepted
    expect(result.citations).to eq([{"page" => 2}])
  end

  it "propagates transport faults instead of making them low-quality results" do
    failure = Phronomy::LLMAdapter::TransportError.new("offline")
    responses << failure
    expect { pipeline { |p| p.invoke("q") } }.to raise_error { |error| expect(error).to equal(failure) }
  end
  it "embeds local citation references without changing their document root" do
    citation = {:type => "object", "$defs" => {page: {type: "integer", minimum: 1}},
                :properties => {page: {"$ref" => "#/$defs/page"}}, :required => ["page"], :additionalProperties => false}
    responses.concat(['{"answer":"ok","confidence":0.9,"citations":[{"page":2}]}', '{"approved":true,"score":0.9,"feedback":""}'])
    result = pipeline(citation_schema: citation) { |p| p.invoke("q") }
    expect(result).to be_accepted
    expect(requests.first.response_schema.dig("properties", "citations", "items", "properties", "page", "$ref"))
      .to eq("#/properties/citations/items/$defs/page")
  end
end
