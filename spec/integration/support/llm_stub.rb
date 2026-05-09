# frozen_string_literal: true

require "webmock/rspec"
require "json"

# Shared LLM stub for integration tests.
#
# Intercepts POST requests to the chat/completions and embeddings endpoints
# with WebMock, records every request body, and returns configurable responses.
#
# == Basic usage (text responses)
#
#   before { @llm = LLMStub.activate(responses: ["Got it.", "Alice"]) }
#   after  { LLMStub.deactivate }
#
# == Tool-call response
#
#   tool_resp = LLMStub.tool_call_response("calculator", {a: 3, b: 4})
#   before { @llm = LLMStub.activate(responses: [tool_resp, "7"]) }
#
# == Embeddings
#
#   before { @llm = LLMStub.activate_with_embeddings(vectors: [[0.1, 0.2]]) }
#
# == Asserting on sent messages
#
#   expect(@llm.messages_for(1)).to include(
#     hash_including("content" => /entity_facts/m)
#   )
#   expect(@llm.last_messages).to include(hash_including("role" => "user"))
#
# The stub returns responses in order; the last response is repeated for any
# additional calls beyond the end of the array.
module LLMStub
  CHAT_ENDPOINT_PATTERN = /chat\/completions/
  EMBEDDINGS_ENDPOINT_PATTERN = /embeddings/

  # Activate the chat completions stub and return a Recorder.
  # responses: Array of either String (text) or Hash (tool_call/raw response).
  def self.activate(responses: ["OK"])
    WebMock.disable_net_connect!

    recorder = Recorder.new(Array(responses))

    WebMock.stub_request(:post, CHAT_ENDPOINT_PATTERN)
      .to_return { |req| recorder.handle(req) }

    recorder
  end

  # Activate both chat completions and embeddings stubs.
  # vectors: Array of embedding vectors (Array of Float) to return in order.
  def self.activate_with_embeddings(responses: ["OK"], vectors: [[0.1, 0.2, 0.3]])
    recorder = activate(responses: responses)

    embed_recorder = EmbeddingsRecorder.new(Array(vectors))
    WebMock.stub_request(:post, EMBEDDINGS_ENDPOINT_PATTERN)
      .to_return { |req| embed_recorder.handle(req) }

    recorder
  end

  # Remove all stubs and re-allow real network connections.
  def self.deactivate
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  # Build a tool-call response Hash that can be passed as a response item.
  # name:      tool/function name (String)
  # arguments: Hash of arguments to serialize as JSON
  def self.tool_call_response(name, arguments = {})
    {
      _type: :tool_call,
      name: name.to_s,
      arguments: arguments
    }
  end

  # Records LLM chat completion API calls and returns configured stub responses.
  class Recorder
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    # Returns the "messages" array from the nth call (0-indexed).
    def messages_for(call_index)
      @calls.dig(call_index, "messages") || []
    end

    # Returns the "messages" array from the most recent call.
    def last_messages
      messages_for(@calls.size - 1)
    end

    # Handles one incoming WebMock request: records it and returns a stub response.
    def handle(request)
      body = JSON.parse(request.body)
      @calls << body

      index = [(@calls.size - 1), (@responses.size - 1)].min
      response = @responses[index]

      {
        status: 200,
        headers: {"Content-Type" => "application/json"},
        body: build_response(response).to_json
      }
    end

    private

    def build_response(response)
      if response.is_a?(Hash) && response[:_type] == :tool_call
        tool_call_response(response[:name], response[:arguments])
      elsif response.is_a?(Hash) && response.key?("choices")
        # Raw pre-built response — pass through as-is
        response
      else
        text_response(response.to_s)
      end
    end

    # Builds a minimal OpenAI-compatible text completion response.
    def text_response(content)
      {
        "id" => "chatcmpl-stub-#{@calls.size}",
        "object" => "chat.completion",
        "created" => 0,
        "model" => "stub-model",
        "choices" => [
          {
            "index" => 0,
            "message" => {"role" => "assistant", "content" => content},
            "logprobs" => nil,
            "finish_reason" => "stop"
          }
        ],
        "usage" => {"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }
    end

    # Builds an OpenAI-compatible tool_calls response.
    def tool_call_response(name, arguments)
      {
        "id" => "chatcmpl-stub-#{@calls.size}",
        "object" => "chat.completion",
        "created" => 0,
        "model" => "stub-model",
        "choices" => [
          {
            "index" => 0,
            "message" => {
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                {
                  "id" => "call_stub_#{@calls.size}",
                  "type" => "function",
                  "function" => {
                    "name" => name,
                    "arguments" => arguments.to_json
                  }
                }
              ]
            },
            "logprobs" => nil,
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => {"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }
    end
  end

  # Records embeddings API calls and returns configured stub vectors.
  class EmbeddingsRecorder
    attr_reader :calls

    def initialize(vectors)
      @vectors = vectors
      @calls = []
      @total_returned = 0
    end

    def handle(request)
      body = JSON.parse(request.body)
      @calls << body

      # Support batched input (array of strings).
      # Use @total_returned as the global offset so that sequential single-embed
      # calls (offset grows by 1 each time) and batched calls both work correctly.
      inputs = Array(body["input"])
      offset = @total_returned
      @total_returned += inputs.size

      data = inputs.each_with_index.map do |_input, i|
        vec = @vectors[[offset + i, @vectors.size - 1].min]
        {"object" => "embedding", "index" => i, "embedding" => vec}
      end

      {
        status: 200,
        headers: {"Content-Type" => "application/json"},
        body: {
          "object" => "list",
          "data" => data,
          "model" => "stub-embedding-model",
          "usage" => {"prompt_tokens" => inputs.size, "total_tokens" => inputs.size}
        }.to_json
      }
    end
  end
end
