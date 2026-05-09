# frozen_string_literal: true

require "webmock/rspec"
require "json"

# Shared LLM stub for integration tests.
#
# Intercepts POST requests to the chat completions endpoint with WebMock,
# records every request body as a parsed Hash, and returns a configurable
# sequence of response strings.
#
# Setup / teardown (call in before/after blocks inside each example group):
#
#   before { @llm = LLMStub.activate(responses: ["Got it.", "Alice"]) }
#   after  { LLMStub.deactivate }
#
# Asserting on sent messages:
#
#   # messages array sent on the 2nd LLM call (0-indexed)
#   expect(@llm.messages_for(1)).to include(
#     hash_including("role" => "system", "content" => /name.*Alice/m)
#   )
#
#   # shorthand for the last call
#   expect(@llm.last_messages).to include(hash_including("role" => "user"))
#
# The stub returns responses in order; the last response is repeated for any
# additional calls beyond the end of the array.
module LLMStub
  CHAT_ENDPOINT_PATTERN = /chat\/completions/

  # Activate the stub and return a Recorder.
  # responses: Array of assistant content strings returned in call order.
  def self.activate(responses: ["OK"])
    WebMock.disable_net_connect!

    recorder = Recorder.new(Array(responses))

    WebMock.stub_request(:post, CHAT_ENDPOINT_PATTERN)
      .to_return { |req| recorder.handle(req) }

    recorder
  end

  # Remove all stubs and re-allow real network connections.
  def self.deactivate
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  # Records LLM API calls and returns configured stub responses.
  class Recorder
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = [] # each element: parsed JSON body Hash
    end

    # Returns the "messages" array from the nth call (0-indexed).
    # Returns an empty array if the call did not occur or had no messages key.
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

      {
        status: 200,
        headers: {"Content-Type" => "application/json"},
        body: openai_response(@responses[index]).to_json
      }
    end

    private

    # Builds a minimal OpenAI-compatible chat completion response body.
    def openai_response(content)
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
  end
end
