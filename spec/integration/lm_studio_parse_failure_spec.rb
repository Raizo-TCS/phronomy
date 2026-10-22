# frozen_string_literal: true

require_relative "spec_helper"
require "socket"
require "json"

RSpec.describe "LM Studio output failure policy over HTTP", :integration do
  let(:engine_error) do
    {"code" => 500, "type" => "server_error",
     "message" => "The model produced output that does not match the expected peg-native format"}
  end
  # These envelopes are synthetic, based on the captured engine/SDK message.
  # They are not claimed to be the missing original failed HTTP response.
  let(:failure_body) { {"error" => "Engine protocol predict stream returned an error: #{JSON.generate(engine_error)}"} }
  let(:success_body) do
    {id: "completion-1", object: "chat.completion", model: "openai/gpt-oss-20b",
     choices: [{index: 0, message: {role: "assistant", content: "package main\nfunc main() {}"}, finish_reason: "stop"}],
     usage: {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}}
  end
  let(:events) { [] }
  let(:request) do
    Phronomy::LLMAdapter::Request.new(message: "Write Go code only", system: "Programming expert",
      model_config: {model: "openai/gpt-oss-20b", provider: "openai"})
  end

  around do |example|
    WebMock.disable! if defined?(WebMock)
    example.run
  ensure
    WebMock.enable! if defined?(WebMock)
  end

  after { Phronomy.reset_configuration! }

  def with_server(responses)
    server = TCPServer.new("127.0.0.1", 0)
    requests = Queue.new
    listener = Thread.new do
      index = 0
      loop do
        client = server.accept
        begin
          headers = []
          while (line = client.gets) && line != "\r\n"
            headers << line
          end
          length = headers.find { |h| h.match?(/\AContent-Length:/i) }.to_s.split(":", 2).last.to_i
          requests << JSON.parse(client.read(length))
          status, body, content_type = responses.fetch([index, responses.length - 1].min)
          index += 1
          data = body.is_a?(String) ? body : JSON.generate(body)
          client.write("HTTP/1.1 #{status} Test\r\nContent-Type: #{content_type || "application/json"}\r\nContent-Length: #{data.bytesize}\r\nConnection: close\r\n\r\n#{data}")
        ensure
          client.close
        end
      end
    rescue IOError, Errno::EBADF
      raise unless server.closed?
    end
    context = RubyLLM.context do |config|
      config.openai_api_key = "local-test-only"
      config.openai_api_base = "http://127.0.0.1:#{server.addr[1]}/v1"
      config.openai_protocol = :chat_completions
      config.request_timeout = 2
      config.max_retries = 3
      config.retry_interval = 0
    end
    yield context, requests
  ensure
    server&.close
    listener&.value
  end

  def adapter(context, retries: 0, observer: nil)
    Phronomy::LLMAdapter::LMStudio.new(context: context, max_parse_retries: retries,
      on_attempt: observer || ->(event) { events << event })
  end

  [400, 500].each do |status|
    it "classifies actual HTTP #{status}, preserves its cause, and does not retry by default" do
      with_server([[status, failure_body]]) do |context, requests|
        expect { adapter(context).complete(request) }.to raise_error(Phronomy::LLMAdapter::TransportError) { |error|
          expect(error.code).to eq("llm.provider_output_parse_failed")
          expect(error.cause.response.status).to eq(status)
          expect(JSON.parse(error.cause.response.body)).to eq(failure_body)
        }
        expect(requests.size).to eq(1)
        expect(events).to contain_exactly(include(attempt: 1, outcome: :failed, http_status: status, retrying: false))
      end
    end

    it "retries HTTP #{status} once with byte-equivalent JSON and retains the first failure event" do
      with_server([[status, failure_body], [200, success_body]]) do |context, requests|
        original_global = RubyLLM.config.max_retries
        result = adapter(context, retries: 1).complete(request)
        expect(result.content).to include("package main")
        expect(requests.size).to eq(2)
        expect(requests.pop).to eq(requests.pop)
        expect(events.map { |event| event[:outcome] }).to eq([:failed, :succeeded])
        expect(events.first).to include(code: "llm.provider_output_parse_failed", retrying: true)
        expect(events.all?(&:frozen?)).to be(true)
        expect(context.config.max_retries).to eq(3)
        expect(RubyLLM.config.max_retries).to eq(original_global)
      end
    end

    it "stops after two HTTP #{status} failures even when the supplied SDK context enables retries" do
      with_server([[status, failure_body]]) do |context, requests|
        expect { adapter(context, retries: 1).complete(request) }.to raise_error(Phronomy::LLMAdapter::TransportError) { |error|
          expect(error.code).to eq("llm.provider_output_parse_failed")
          expect(error.cause.response.status).to eq(status)
        }
        expect(requests.size).to eq(2)
        expect(events.map { |event| event[:retrying] }).to eq([true, false])
      end
    end
  end

  [
    {"error" => "parse failed"},
    {"error" => {"message" => "The model produced output that does not match the expected peg-native format"}},
    {"error" => "Engine protocol predict stream returned an error: {invalid"},
    {"error" => {"code" => 500, "type" => "other", "message" => "The model produced output that does not match the expected peg-native format"}},
    {"error" => {"code" => "500", "type" => "server_error", "message" => "The model produced output that does not match the expected peg-native format"}}
  ].each_with_index do |body, index|
    it "does not classify or retry unknown response shape #{index}" do
      with_server([[500, body]]) do |context, requests|
        expect { adapter(context, retries: 1).complete(request) }.to raise_error(Phronomy::LLMAdapter::TransportError) { |error|
          expect(error.code).to be_nil
          expect(error.cause.response.status).to eq(500)
        }
        expect(requests.size).to eq(1)
      end
    end
  end

  it "accepts only the exact nested engine payload inside the structured error envelope" do
    with_server([[400, {"error" => {"message" => failure_body.fetch("error")}}]]) do |context, requests|
      expect { adapter(context).complete(request) }.to raise_error(Phronomy::LLMAdapter::TransportError) { |error|
        expect(error.code).to eq("llm.provider_output_parse_failed")
      }
      expect(requests.size).to eq(1)
    end
  end

  it "does not turn authentication failure into a parse failure even with the same body" do
    with_server([[401, failure_body]]) do |context, requests|
      expect { adapter(context, retries: 1).complete(request) }.to raise_error(Phronomy::LLMAdapter::AuthenticationError)
      expect(requests.size).to eq(1)
    end
  end

  it "does not retry a stream" do
    with_server([[400, failure_body]]) do |context, requests|
      expect { adapter(context, retries: 1).stream(request) { |_chunk| } }
        .to raise_error(Phronomy::LLMAdapter::TransportError) { |error| expect(error.code).to eq("llm.provider_output_parse_failed") }
      expect(requests.size).to eq(1)
    end
  end

  [:tools, :schema, :model].each do |excluded|
    it "does not retry when #{excluded} is outside the accepted retry scope" do
      options = {message: request.message, model_config: request.model_config}
      options[:tools] = [{name: "lookup", description: "inert", parameters_schema: {"type" => "object", "properties" => {}}}] if excluded == :tools
      options[:response_schema] = {type: "object", properties: {}} if excluded == :schema
      options[:model_config] = {model: "other-model", provider: "openai"} if excluded == :model
      with_server([[400, failure_body]]) do |context, requests|
        expect { adapter(context, retries: 1).complete(Phronomy::LLMAdapter::Request.new(**options)) }
          .to raise_error(Phronomy::LLMAdapter::TransportError)
        expect(requests.size).to eq(1)
      end
    end
  end

  it "honors cancellation between attempts without a second POST" do
    token = Phronomy::Concurrency::CancellationToken.new
    with_server([[400, failure_body], [200, success_body]]) do |context, requests|
      selected = adapter(context, retries: 1, observer: ->(_event) { token.cancel! })
      expect { selected.complete(request, cancellation_token: token) }.to raise_error(Phronomy::CancellationError)
      expect(requests.size).to eq(1)
    end
  end

  it "preserves streaming callback exception identity and never replays delivered output" do
    chunk = {id: "chunk", model: "openai/gpt-oss-20b", choices: [{index: 0, delta: {content: "part"}, finish_reason: nil}]}
    data = "data: #{JSON.generate(chunk)}\n\ndata: [DONE]\n\n"
    source = Phronomy::LLMAdapter::TransportError.new("callback", code: "llm.provider_output_parse_failed")
    with_server([[200, data, "text/event-stream"]]) do |context, requests|
      expect { adapter(context, retries: 1).stream(request) { raise source } }
        .to raise_error { |error| expect(error).to equal(source) }
      expect(requests.size).to eq(1)
    end
  end

  it "ignores diagnostic callback failures and cannot be reconfigured through the caller context" do
    with_server([[400, failure_body], [200, success_body]]) do |context, requests|
      selected = adapter(context, retries: 1, observer: ->(_event) { raise "diagnostic failed" })
      context.config.max_retries = 20
      expect(selected.complete(request).content).to include("package main")
      expect(requests.size).to eq(2)
    end
  end

  it "leaves the default RubyLLM backend's SDK retry behavior unchanged" do
    with_server([[500, failure_body]]) do |context, requests|
      expect { Phronomy::LLMAdapter::RubyLLM.new(context: context).complete(request) }
        .to raise_error(Phronomy::LLMAdapter::TransportError) { |error| expect(error.code).to be_nil }
      expect(requests.size).to eq(4)
    end
  end

  it "rejects an unbounded retry setting before any generation POST" do
    with_server([[200, success_body]]) do |context, requests|
      expect { adapter(context, retries: 2) }.to raise_error(ArgumentError)
      expect(requests.size).to eq(0)
    end
  end

  it "keeps failure observation when the configured SDK logger raises" do
    with_server([[400, failure_body], [200, success_body]]) do |context, requests|
      logger = double("logger")
      allow(logger).to receive(:warn).and_raise("logger failed")
      context.config.logger = logger
      expect(adapter(context, retries: 1).complete(request).content).to include("package main")
      expect(requests.size).to eq(2)
      expect(events.map { |event| event[:outcome] }).to eq([:failed, :succeeded])
    end
  end
end
