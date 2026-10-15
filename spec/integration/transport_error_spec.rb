# frozen_string_literal: true

require_relative "spec_helper"
require "socket"
require "json"

RSpec.describe "RubyLLM HTTP failure boundaries", :integration do
  let(:request) { Phronomy::LLMAdapter::Request.new(message: "input", model_config: {model: "local-transport-test", provider: "openai"}) }
  let(:adapter) { Phronomy::LLMAdapter::RubyLLM.new }

  around do |example|
    fields = %i[openai_api_key openai_api_base openai_protocol request_timeout max_retries]
    saved = fields.to_h { |key| [key, RubyLLM.config.public_send(key)] }
    # Other integration groups load WebMock. Its real-request passthrough buffers
    # streaming bodies, so these real HTTP contracts must bypass its interception.
    WebMock.disable! if defined?(WebMock)
    example.run
  ensure
    saved.each { |key, value| RubyLLM.config.public_send("#{key}=", value) }
    WebMock.enable! if defined?(WebMock)
  end

  # Real loopback HTTP, with no provider/SDK stub. Test-only server threads stay
  # blocked on a Queue until teardown, so timeout behavior does not rely on sleeps.
  def with_fault_server(mode, status: nil, body: nil)
    server = TCPServer.new("127.0.0.1", 0)
    gate = Queue.new
    requests = Queue.new
    workers = []
    listener = Thread.new do
      loop do
        socket = server.accept
        workers << Thread.new(socket) do |client|
          headers = []
          while (line = client.gets) && line != "\r\n"
            headers << line
          end
          length = headers.find { |header| header.match?(/\AContent-Length:/i) }.to_s.split(":", 2).last.to_i
          requests << JSON.parse(client.read(length))
          if mode == :http_error
            data = JSON.generate(body)
            client.write("HTTP/1.1 #{status} Error\r\nContent-Type: application/json\r\nContent-Length: #{data.bytesize}\r\nConnection: close\r\n\r\n#{data}")
          elsif mode != :disconnect
            if mode == :partial_stream
              data = {id: "chunk-1", model: "local-transport-test", choices: [{index: 0, delta: {content: "part"}, finish_reason: nil}]}
              client.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: #{JSON.generate(data)}\n\n")
            end
            gate.pop
          end
        ensure
          client.close
        end
      end
    rescue IOError, Errno::EBADF
      raise unless server.closed?
    end
    RubyLLM.configure do |config|
      config.openai_api_key = "test-only"
      config.openai_api_base = "http://127.0.0.1:#{server.addr[1]}/v1"
      config.openai_protocol = :chat_completions
      config.request_timeout = 0.5
      # Isolate adapter replay from the SDK retry policy unless a test opts in.
      config.max_retries = 0
    end
    yield requests
  ensure
    server&.close
    listener&.join
    workers&.each { gate << true }
    workers&.each(&:value)
  end

  %i[complete stream].each do |operation|
    [
      [400, "Cannot combine structured output constraints with lazy grammar", true, Phronomy::LLMAdapter::StructuredOutputUnsupportedError, RubyLLM::BadRequestError, 1],
      [400, "Invalid conversation", true, Phronomy::LLMAdapter::TransportError, RubyLLM::BadRequestError, 1],
      [400, "Cannot combine structured output constraints with lazy grammar", false, Phronomy::LLMAdapter::TransportError, RubyLLM::BadRequestError, 1],
      [401, "Invalid credentials", true, Phronomy::LLMAdapter::AuthenticationError, RubyLLM::UnauthorizedError, 1],
      [429, "Rate limit", true, Phronomy::LLMAdapter::RateLimitError, RubyLLM::RateLimitError, 4],
      [500, "Cannot combine structured output constraints with lazy grammar", true, Phronomy::LLMAdapter::TransportError, RubyLLM::ServerError, 4]
    ].each do |status, message, structured, owner, source, attempts|
      it "preserves HTTP #{status} for #{operation} (schema=#{structured}, #{message}) with SDK retries enabled" do
        with_fault_server(:http_error, status: status, body: {error: message}) do |requests|
          RubyLLM.config.max_retries = 3
          schema = structured ? {type: "object", properties: {answer: {type: "string"}}, required: ["answer"], additionalProperties: false} : nil
          input = Phronomy::LLMAdapter::Request.new(message: "input", model_config: request.model_config,
            response_schema: schema, tools: [{name: "lookup", description: "Declaration only",
                                              parameters_schema: {"type" => "object", "properties" => {}}}])
          expect { adapter.public_send(operation, input) { |_chunk| } }.to raise_error(owner) { |error|
            expect(error.cause).to be_a(source)
            expect(error.cause.response.status).to eq(status)
          }
          expect(requests.size).to eq(attempts)
          payload = requests.pop
          expect(payload.fetch("tools").length).to eq(1)
          expect(payload.dig("response_format", "type")).to eq(structured ? "json_schema" : nil)
        end
      end
    end
  end

  %i[complete stream embed].each do |operation|
    %i[timeout disconnect].each do |failure|
      it "publishes #{operation} #{failure} as the owner TransportError with its network causes" do
        with_fault_server(failure) do |requests|
          owner = (operation == :embed) ? Phronomy::Embeddings::TransportError : Phronomy::LLMAdapter::TransportError
          source = (failure == :timeout) ? Faraday::TimeoutError : Faraday::ConnectionFailed
          expect {
            if operation == :embed
              Phronomy::Embeddings::RubyLLMEmbeddings.new(model: "local-transport-test", provider: :openai, assume_model_exists: true).embed("input")
            else
              adapter.public_send(operation, request) { |_chunk| }
            end
          }.to raise_error(owner) { |error|
            expect(error.cause).to be_a(source)
            expect(error.cause.cause).to be_a((failure == :timeout) ? Net::ReadTimeout : EOFError)
          }
          expect(requests.size).to eq(1)
        end
      end
    end
  end

  it "retains partial output and surfaces timeout without replay with SDK retries enabled" do
    with_fault_server(:partial_stream) do |requests|
      RubyLLM.config.max_retries = 3
      chunks = []
      expect { adapter.stream(request) { |chunk| chunks << chunk.content } }
        .to raise_error(Phronomy::LLMAdapter::TransportError) { |error| expect(error.cause).to be_a(Faraday::TimeoutError) }
      expect(chunks).to eq(["part"])
      expect(requests.size).to eq(1)
    end
  end

  it "preserves a real streaming callback's Faraday exception with SDK retries enabled" do
    with_fault_server(:partial_stream) do |requests|
      RubyLLM.config.max_retries = 3
      source = Faraday::TimeoutError.new("application callback failed")
      expect { adapter.stream(request) { raise source } }
        .to raise_error { |error| expect(error).to equal(source) }
      expect(requests.size).to eq(1)
    end
  end

  it "propagates the public transport failure through GeneratorVerifier and releases both Agents" do
    with_fault_server(:timeout) do |requests|
      agent = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "transport-error-pipeline", version: 1
        model "local-transport-test"
        provider :openai
      end
      pipeline = nil
      expect {
        Phronomy::GeneratorVerifier.open(draft_agent: agent, review_agent: agent,
          draft_prompt_builder: ->(input, _feedback) { input },
          review_prompt_builder: ->(input, _draft, _citations) { input }) do |owned|
          pipeline = owned
          owned.invoke_async("input")
        end
      }.to raise_error(Phronomy::LLMAdapter::TransportError) { |error|
        expect(error.cause).to be_a(Faraday::TimeoutError)
        expect(error.cause.cause).to be_a(Net::ReadTimeout)
      }
      expect(pipeline.release!).to be false
      expect(requests.size).to eq(1)
    end
  end
end
