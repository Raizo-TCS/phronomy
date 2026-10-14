# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe "Structured output native protocol contracts" do
  let(:schema) { {"type" => "object", "properties" => {"score" => {"type" => "number", "minimum" => 0, "maximum" => 1}}, "required" => ["score"], "additionalProperties" => false} }
  let(:adapter) { Phronomy::LLMAdapter::RubyLLM.new }
  around do |example|
    config = RubyLLM.config
    fields = %i[openai_api_key openai_api_base openai_protocol azure_api_key azure_api_base azure_protocol anthropic_api_key anthropic_api_base gemini_api_key gemini_api_base ollama_api_base]
    saved = fields.to_h { |key| [key, config.public_send(key)] }
    fields.each { |key| config.public_send("#{key}=", key.to_s.end_with?("api_base") ? "https://structured.example.test/v1" : "test-only") }
    config.openai_protocol = config.azure_protocol = :chat_completions
    WebMock.enable!
    WebMock.disable_net_connect!
    example.run
  ensure
    saved.each { |key, value| config.public_send("#{key}=", value) }
  end

  [%w[openai chat_completions], %w[openai responses], %w[azure chat_completions], %w[azure responses],
    %w[anthropic anthropic], %w[gemini gemini], %w[ollama chat_completions]].each do |provider, protocol|
    it "preserves validation keywords in #{provider}/#{protocol}" do
      RubyLLM.config.public_send("#{provider}_protocol=", protocol.to_sym) if %w[openai azure].include?(provider)
      sent = nil
      body = case protocol
      when "responses"
        {id: "resp_1", object: "response", model: "local-schema-test", status: "completed",
         output: [{type: "message", role: "assistant", content: [{type: "output_text", text: '{"score":0.5}'}]}]}
      when "anthropic"
        {id: "msg_1", type: "message", role: "assistant", model: "local-schema-test", content: [{type: "text", text: '{"score":0.5}'}], stop_reason: "end_turn", usage: {input_tokens: 1, output_tokens: 1}}
      when "gemini"
        {candidates: [{content: {role: "model", parts: [{text: '{"score":0.5}'}]}, finishReason: "STOP"}]}
      else
        {id: "chatcmpl_1", object: "chat.completion", model: "local-schema-test", choices: [{index: 0, finish_reason: "stop", message: {role: "assistant", content: '{"score":0.5}'}}]}
      end
      stub_request(:post, %r{\Ahttps://structured.example.test/}).to_return do |http|
        sent = JSON.parse(http.body)
        {status: 200, headers: {"Content-Type" => "application/json"}, body: JSON.generate(body)}
      end
      response = adapter.complete(Phronomy::LLMAdapter::Request.new(message: "score", response_schema: schema,
        model_config: {model: "local-schema-test", provider: provider}))
      transmitted = case protocol
      when "responses" then sent.dig("text", "format", "schema")
      when "anthropic" then sent.dig("output_config", "format", "schema")
      when "gemini" then sent.dig("generationConfig", "responseJsonSchema")
      else sent.dig("response_format", "json_schema", "schema")
      end
      expect(transmitted).to eq(schema)
      expect(response.finish_reason).to eq(:stop)
    end
  end

  it "keeps an unknown SDK/internal failure intact" do
    failure = RuntimeError.new("SDK bug")
    allow(RubyLLM).to receive(:chat).and_raise(failure)
    expect { adapter.complete(Phronomy::LLMAdapter::Request.new(response_schema: schema)) }.to raise_error { |error| expect(error).to equal(failure) }
  end
end
