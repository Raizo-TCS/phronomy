# frozen_string_literal: true

require "spec_helper"

# ---------------------------------------------------------------------------
# Test agents
# ---------------------------------------------------------------------------
class StreamingBasicAgent < Phronomy::Agent::Base
  model "test-model"
  instructions "You are a helpful assistant."
end

class StreamingReactAgent < Phronomy::Agent::ReactAgent
  model "test-model"
  instructions "You are a ReAct assistant."
end

# ---------------------------------------------------------------------------
RSpec.describe "Agent streaming" do
  let(:fake_tokens) { double("Tokens", input: 10, output: 5, cached: 0, cache_creation: 0) }
  let(:fake_response) { double("Response", content: "Hello, world!", tool_calls: nil, tokens: fake_tokens) }

  # Build a chat double that supports streaming callbacks
  def build_streaming_chat(response)
    dbl = double("Chat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
    allow(dbl).to receive(:with_temperature).and_return(dbl)
    allow(dbl).to receive(:messages).and_return([response])
    allow(dbl).to receive(:before_tool_call)
    allow(dbl).to receive(:after_tool_result)
    allow(dbl).to receive(:ask) do |_msg, &blk|
      blk&.call(double("Chunk", content: "Hello, world!"))
      response
    end
    allow(dbl).to receive(:complete) do |&blk|
      blk&.call(double("Chunk", content: "Hello, world!"))
      response
    end
    dbl
  end

  before do
    allow(RubyLLM).to receive(:chat).and_return(build_streaming_chat(fake_response))
  end

  # -------------------------------------------------------------------------
  describe Phronomy::Agent::StreamEvent do
    it "is a Data type with :type and :payload attributes" do
      event = described_class.new(type: :token, payload: {content: "hi"})
      expect(event.type).to eq(:token)
      expect(event.payload).to eq({content: "hi"})
    end

    it "is frozen (Data semantics)" do
      event = described_class.new(type: :done, payload: {output: "x"})
      expect(event).to be_frozen
    end
  end

  # -------------------------------------------------------------------------
  describe Phronomy::Agent::Base, "#stream" do
    subject(:agent) { StreamingBasicAgent.new }

    it "yields :token events for each LLM chunk" do
      events = []
      agent.stream("Hello") { |e| events << e }
      token_events = events.select { |e| e.type == :token }
      expect(token_events).not_to be_empty
      expect(token_events.first.payload[:content]).to be_a(String)
    end

    it "yields a :done event as the final event" do
      events = []
      agent.stream("Hello") { |e| events << e }
      expect(events.last.type).to eq(:done)
    end

    it "includes output in the :done payload" do
      done_payload = nil
      agent.stream("Hello") { |e| done_payload = e.payload if e.type == :done }
      expect(done_payload[:output]).to eq("Hello, world!")
    end

    it "returns the same hash as #invoke" do
      result = agent.stream("Hello") { |_e| }
      expect(result).to include(:output, :messages, :usage)
      expect(result[:output]).to eq("Hello, world!")
    end

    it "falls back to #invoke when no block is given" do
      result = agent.stream("Hello")
      expect(result[:output]).to eq("Hello, world!")
    end

    context "when an error occurs" do
      before do
        bad_chat = double("Chat")
        allow(bad_chat).to receive(:with_instructions).and_return(bad_chat)
        allow(bad_chat).to receive(:with_tool).and_return(bad_chat)
        allow(bad_chat).to receive(:with_temperature).and_return(bad_chat)
        allow(bad_chat).to receive(:before_tool_call)
        allow(bad_chat).to receive(:after_tool_result)
        allow(bad_chat).to receive(:ask).and_raise(RuntimeError, "LLM exploded")
        allow(RubyLLM).to receive(:chat).and_return(bad_chat)
      end

      it "yields an :error event before re-raising" do
        events = []
        expect do
          agent.stream("boom") { |e| events << e }
        end.to raise_error(RuntimeError, "LLM exploded")
        expect(events.map(&:type)).to include(:error)
        expect(events.find { |e| e.type == :error }.payload[:error]).to be_a(RuntimeError)
      end
    end
  end

  # -------------------------------------------------------------------------
  describe Phronomy::Agent::ReactAgent, "#stream" do
    subject(:agent) { StreamingReactAgent.new }

    it "yields :token events" do
      events = []
      agent.stream("What is 2+2?") { |e| events << e }
      expect(events.any? { |e| e.type == :token }).to be(true)
    end

    it "yields a :done event last" do
      events = []
      agent.stream("What is 2+2?") { |e| events << e }
      expect(events.last.type).to eq(:done)
    end

    it "returns a hash with :output" do
      result = agent.stream("What is 2+2?") { |_e| }
      expect(result[:output]).to be_a(String)
    end

    it "falls back to #invoke when no block given" do
      result = agent.stream("What is 2+2?")
      expect(result[:output]).to eq("Hello, world!")
    end
  end
end
