# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe "RubyLLM conversation continuation metadata" do
  let(:adapter) { Phronomy::LLMAdapter::RubyLLM.new }
  let(:model) { "local-reasoning-model" }
  let(:config) { {model: model, provider: "openai", assume_model_exists: true} }
  let(:endpoint) { "https://continuation.example.test/v1/chat/completions" }
  let(:tools) { [{name: "lookup", description: "Lookup", parameters_schema: {"type" => "object", "properties" => {}, "required" => []}}] }
  let(:text) { "synthetic continuation text" }
  let(:signature) { "synthetic opaque signature" }

  around do |example|
    fields = %i[openai_api_key openai_api_base openai_protocol openrouter_api_key openrouter_api_base]
    saved = fields.to_h { |name| [name, RubyLLM.config.public_send(name)] }
    RubyLLM.configure do |c|
      c.openai_api_key = "test"
      c.openai_api_base = "https://continuation.example.test/v1"
      c.openai_protocol = :chat_completions
      c.openrouter_api_key = "test"
      c.openrouter_api_base = "https://continuation.example.test/v1"
    end
    example.run
  ensure
    saved.each { |name, value| RubyLLM.config.public_send("#{name}=", value) }
  end

  def wire_response(thinking: true)
    message = {role: "assistant", content: "", tool_calls: [{id: "call-1", type: "function", function: {name: "lookup", arguments: "{}"}}]}
    if thinking
      message[:reasoning] = text
      message[:reasoning_signature] = signature
    end
    {model: model, choices: [{index: 0, message: message, finish_reason: "tool_calls"}], usage: {prompt_tokens: 3, completion_tokens: 2}}
  end

  def request(messages: [Phronomy::LLMAdapter::Message.new(role: :user, content: "lookup")], model_config: config)
    Phronomy::LLMAdapter::Request.new(model_config: model_config, messages: messages, tools: tools)
  end

  def complete_round(response)
    adapter.complete(request(messages: [response, Phronomy::LLMAdapter::Message.new(role: :tool, tool_call_id: "call-1", content: "found")]))
  end

  def stub_completion(body = wire_response)
    stub_request(:post, endpoint).to_return(headers: {"Content-Type" => "application/json"}, body: JSON.generate(body))
  end

  it "preserves text and signature through canonical Response serialization and the next HTTP request" do
    requests = []
    stub_request(:post, endpoint).to_return do |r|
      requests << JSON.parse(r.body)
      {headers: {"Content-Type" => "application/json"}, body: JSON.generate(wire_response)}
    end
    first = adapter.complete(request(messages: [Phronomy::LLMAdapter::Message.new(role: :user, content: "lookup")]))
    expect(first.content).to eq("")
    expect(first.metadata.fetch("ruby_llm_continuation")).to be_frozen
    restored = Phronomy::LLMAdapter::Response.from_h(JSON.parse(JSON.generate(first.to_h)))
    complete_round(restored)
    assistant = requests.last.fetch("messages").find { |m| m["role"] == "assistant" }
    expect(assistant).to include("reasoning" => text, "reasoning_content" => text, "reasoning_signature" => signature)
    expect(assistant.fetch("tool_calls").first.fetch("id")).to eq("call-1")
    expect(requests.last.fetch("messages").last).to include("tool_call_id" => "call-1", "content" => "found")
  end

  it "retains streamed reasoning in the final Response without exposing it as answer chunks" do
    chunks = [
      {reasoning: "synthetic "}, {reasoning: "continuation text", reasoning_signature: signature},
      {tool_calls: [{index: 0, id: "call-1", type: "function", function: {name: "lookup", arguments: "{}"}}]}
    ].map { |delta| {model: model, choices: [{index: 0, delta: delta, finish_reason: nil}]} }
    chunks << {model: model, choices: [{index: 0, delta: {}, finish_reason: "tool_calls"}]}
    stub_request(:post, endpoint).to_return(headers: {"Content-Type" => "text/event-stream"}, body: chunks.map { |c| "data: #{JSON.generate(c)}\n\n" }.join + "data: [DONE]\n\n")
    delivered = []
    first = adapter.stream(request) { |c| delivered << c.content }
    stub_completion
    complete_round(first)
    expect(delivered.compact.join).to eq("")
    expect(WebMock).to have_requested(:post, endpoint).with { |r|
      JSON.parse(r.body)["messages"].any? { |m| m["reasoning"] == text && m["reasoning_signature"] == signature }
    }
  end

  it "preserves the SDK's provider-shaped reasoning blocks" do
    blocks = [{"type" => "reasoning.encrypted", "data" => "opaque", "id" => "reason-1", "format" => "provider-v1", "index" => 0}]
    body = wire_response
    body[:choices][0][:message][:reasoning_details] = blocks
    stub_completion(body)
    routed = config.merge(provider: "openrouter")
    first = adapter.complete(request(model_config: routed))
    adapter.complete(request(model_config: routed, messages: [first, Phronomy::LLMAdapter::Message.new(role: :tool, tool_call_id: "call-1", content: "found")]))
    expect(WebMock).to have_requested(:post, endpoint).with { |r|
      JSON.parse(r.body)["messages"].any? { |m| m["reasoning_details"] == blocks }
    }
  end

  it "retains encrypted reasoning for the existing Responses protocol" do
    RubyLLM.config.openai_protocol = :responses
    body = {id: "resp-1", model: model, status: "completed", output: [
      {type: "reasoning", id: "r-1", summary: [{type: "summary_text", text: text}], encrypted_content: signature},
      {type: "function_call", id: "fc-1", call_id: "call-1", name: "lookup", arguments: "{}", status: "completed"}
    ], usage: {input_tokens: 3, output_tokens: 2}}
    url = endpoint.sub("chat/completions", "responses")
    stub_request(:post, url).to_return(headers: {"Content-Type" => "application/json"}, body: JSON.generate(body))
    first = adapter.complete(request)
    complete_round(first)
    expect(WebMock).to have_requested(:post, url).with { |r|
      JSON.parse(r.body)["input"].any? { |item| item["type"] == "reasoning" && item["encrypted_content"] == signature }
    }
  end

  it "keeps legacy messages without continuation metadata usable" do
    stub_completion(wire_response(thinking: false))
    response = adapter.complete(request)
    expect(response.metadata).not_to have_key("ruby_llm_continuation")
    expect { complete_round(response) }.not_to raise_error
  end

  %i[model provider endpoint protocol version].each do |change|
    it "rejects incompatible #{change} before another HTTP request instead of dropping or replaying state" do
      stub_completion
      first = adapter.complete(request)
      WebMock.reset!
      model_config = config
      case change
      when :model then model_config = config.merge(model: "different-model")
      when :provider then model_config = config.merge(provider: "openrouter")
      when :endpoint then RubyLLM.config.openai_api_base = "https://other.example.test/v1"
      when :protocol then RubyLLM.config.openai_protocol = :responses
      when :version
        hash = JSON.parse(JSON.generate(first.to_h))
        hash.fetch("metadata").fetch("ruby_llm_continuation")["version"] = 99
        first = Phronomy::LLMAdapter::Response.from_h(hash)
      end
      expect { adapter.complete(request(model_config: model_config, messages: [first])) }
        .to raise_error(Phronomy::ConfigurationError, /continuation/)
    end
  end
end
