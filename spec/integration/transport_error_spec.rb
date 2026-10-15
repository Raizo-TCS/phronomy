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
  def with_fault_server(mode)
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
          client.read(length)
          requests << headers.first
          unless mode == :disconnect
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
