# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe "RubyLLM native structured output transport" do
  let(:schema) { {"type" => "object", "properties" => {"score" => {"type" => "number", "minimum" => 0, "maximum" => 1}}, "required" => ["score"], "additionalProperties" => false} }
  let(:adapter) { Phronomy::LLMAdapter::RubyLLM.new }
  before do
    @previous = [RubyLLM.config.openai_api_key, RubyLLM.config.openai_api_base, RubyLLM.config.openai_protocol]
    WebMock.enable!
    WebMock.disable_net_connect!
    RubyLLM.configure do |config|
      config.openai_api_key = "test-only"
      config.openai_api_base = "https://api.openai.com/v1"
      config.openai_protocol = :chat_completions
    end
  end
  after do
    config = RubyLLM.config
    config.openai_api_key, config.openai_api_base, config.openai_protocol = @previous
  end
  def request(model: "gpt-4o", **options)
    Phronomy::LLMAdapter::Request.new(model_config: {model: model, provider: "openai"},
      message: "score", response_schema: schema, **options)
  end

  def completion(content: '{"score":0.5}', finish_reason: "stop", refusal: nil)
    {id: "chatcmpl-structured", object: "chat.completion", model: "gpt-4o",
     choices: [{index: 0, finish_reason: finish_reason, message: {role: "assistant", content: content, refusal: refusal}}]}
  end
  it "sends the full native schema including numeric constraints for an unregistered model" do
    payload = nil
    stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return do |http|
      payload = JSON.parse(http.body)
      {status: 200, headers: {"Content-Type" => "application/json"}, body: JSON.generate(completion)}
    end
    response = adapter.complete(request(model: "local-test-model-not-in-catalog"))
    expect(payload.dig("response_format", "type")).to eq("json_schema")
    expect(payload.dig("response_format", "json_schema", "schema")).to eq(schema)
    expect(response.finish_reason).to eq(:stop)
    expect(response.metadata["raw_finish_reason"]).to eq("stop")
  end
  it "retains refusal as distinct from valid JSON content" do
    stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(status: 200,
      headers: {"Content-Type" => "application/json"}, body: JSON.generate(completion(refusal: "cannot answer")))
    response = adapter.complete(request)
    expect(response.finish_reason).to eq(:refusal)
    expect(response.refusal).to eq("cannot answer")
  end
  it "maps native schema rejection without weakening and replaying the request" do
    endpoint = stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(status: 400,
      headers: {"Content-Type" => "application/json"}, body: JSON.generate(error: {message: "unsupported schema", param: "response_format", code: "invalid_json_schema"}))
    expect { adapter.complete(request) }.to raise_error(Phronomy::LLMAdapter::StructuredOutputUnsupportedError) { |error|
      expect(error.cause).to be_a(RubyLLM::BadRequestError)
    }
    expect(endpoint).to have_been_requested.once
  end
  it "retains streamed refusal even when the SDK omits it from Chunk content" do
    registered = RubyLLM::Providers::OpenAI.protocols.dup
    body = [
      {delta: {refusal: "cannot "}, finish_reason: nil},
      {delta: {refusal: "answer"}, finish_reason: nil},
      {delta: {}, finish_reason: "stop"}
    ].map { |choice| "data: #{JSON.generate(id: "stream-1", model: "gpt-4o", choices: [choice.merge(index: 0)])}\n\n" }.join + "data: [DONE]\n\n"
    stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(status: 200,
      headers: {"Content-Type" => "text/event-stream"}, body: body)
    chunks = []
    result = adapter.stream(request) { |chunk| chunks << chunk }
    expect(result.finish_reason).to eq(:refusal)
    expect(result.refusal).to eq("cannot answer")
    expect(chunks).not_to be_empty
    expect(RubyLLM::Providers::OpenAI.protocols).to eq(registered)
  end

  it "rejects conflicting schema configuration instead of ignoring it" do
    expect { Phronomy::LLMAdapter::Request.new(response_schema: schema, model_config: {provider_options: {response_format: {type: "json_object"}}}) }.to raise_error(ArgumentError)
  end
end
