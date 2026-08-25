# frozen_string_literal: true

require "spec_helper"

class StreamingBasicAgent < Phronomy::Agent::Base
  agent_definition id: "streaming-basic-agent", version: 1
  model "test-model"
  instructions "You are a helpful assistant."
end

class StreamingReactAgent < Phronomy::Agent::Base
  agent_definition id: "streaming-react-agent", version: 1
  model "test-model"
  instructions "You are a helpful assistant."
end

RSpec.describe "Agent streaming" do
  let(:fake_tokens) do
    double(
      "Tokens",
      input: 10,
      output: 5,
      cached: 0,
      cache_creation: 0,
      to_h: {"input" => 10, "output" => 5, "cached" => 0, "cache_creation" => 0}
    )
  end
  let(:fake_response) do
    double(
      "Response",
      role: :assistant,
      content: "Hello, world!",
      tool_calls: nil,
      tokens: fake_tokens,
      tool_call?: false
    )
  end

  def build_streaming_chat(response)
    dbl = double("Chat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
    allow(dbl).to receive(:with_temperature).and_return(dbl)
    allow(dbl).to receive(:cancellation_token=)
    allow(dbl).to receive(:messages).and_return([response])
    allow(dbl).to receive(:on_tool_call)
    allow(dbl).to receive(:before_tool_call)
    allow(dbl).to receive(:on_tool_result)
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

  def event_agent(klass = StreamingBasicAgent, events: [])
    [
      klass.new(on_event: ->(event) { events << event }),
      events
    ]
  end

  before do
    allow(RubyLLM).to receive(:chat).and_return(build_streaming_chat(fake_response))
  end

  after do
    Phronomy.reset_runtime!
  rescue
    nil
  end

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

  describe Phronomy::Agent::Base, "#stream" do
    it "publishes :token events through the Agent-incarnation listener" do
      agent, events = event_agent
      agent.stream("Hello")
      token_events = events.select { |event| event.type == :token }
      expect(token_events).not_to be_empty
      expect(token_events.first.payload[:content]).to be_a(String)
    end

    it "publishes :done as the final event" do
      agent, events = event_agent
      agent.stream("Hello")
      expect(events.last.type).to eq(:done)
    end

    it "includes output in the :done payload" do
      agent, events = event_agent
      agent.stream("Hello")
      done = events.find { |event| event.type == :done }
      expect(done.payload[:output]).to eq("Hello, world!")
    end

    it "returns the same result shape as #invoke" do
      agent, = event_agent
      result = agent.stream("Hello")
      expect(result).to include(:output, :messages, :usage)
      expect(result[:output]).to eq("Hello, world!")
    end

    it "requires an Agent-incarnation listener" do
      expect { StreamingBasicAgent.new.stream("Hello") }
        .to raise_error(ArgumentError, /Agent on_event listener/)
    end

    it "rejects the removed per-invocation stream block" do
      agent, = event_agent
      expect { agent.stream("Hello") { |_event| } }
        .to raise_error(ArgumentError, /no longer register Agent events/)
    end

    context "when an error occurs" do
      before do
        bad_chat = double("Chat")
        allow(bad_chat).to receive(:with_instructions).and_return(bad_chat)
        allow(bad_chat).to receive(:with_tool).and_return(bad_chat)
        allow(bad_chat).to receive(:with_temperature).and_return(bad_chat)
        allow(bad_chat).to receive(:cancellation_token=)
        allow(bad_chat).to receive(:on_tool_call)
        allow(bad_chat).to receive(:before_tool_call)
        allow(bad_chat).to receive(:on_tool_result)
        allow(bad_chat).to receive(:messages).and_return([])
        allow(bad_chat).to receive(:ask).and_raise(RuntimeError, "LLM exploded")
        allow(bad_chat).to receive(:complete).and_raise(RuntimeError, "LLM exploded")
        allow(RubyLLM).to receive(:chat).and_return(bad_chat)
      end

      it "publishes :error before re-raising" do
        agent, events = event_agent
        expect { agent.stream("boom") }
          .to raise_error(RuntimeError, "LLM exploded")
        error_event = events.find { |event| event.type == :error }
        expect(error_event).not_to be_nil
        expect(error_event.payload[:error]).to be_a(RuntimeError)
      end
    end
  end

  describe Phronomy::Agent::Base, "#stream via StreamingReactAgent" do
    it "publishes :token and final :done events" do
      agent, events = event_agent(StreamingReactAgent)
      result = agent.stream("What is 2+2?")
      expect(events.any? { |event| event.type == :token }).to be(true)
      expect(events.last.type).to eq(:done)
      expect(result[:output]).to be_a(String)
    end

    it "requires an Agent-incarnation listener" do
      expect { StreamingReactAgent.new.stream("What is 2+2?") }
        .to raise_error(ArgumentError, /Agent on_event listener/)
    end
  end

  describe "stream produces a trace span (issue #40)" do
    let(:recording_tracer) do
      Class.new(Phronomy::Tracing::Base) do
        attr_reader :spans

        def initialize
          @spans = []
        end

        def start_span(name, **attrs)
          span = {name: name, attrs: attrs}
          @spans << span
          span
        end

        def finish_span(_span, output: nil, usage: nil, error: nil)
          nil
        end
      end.new
    end

    around do |example|
      original = Phronomy.configuration.tracer
      Phronomy.configure { |c| c.tracer = recording_tracer }
      example.run
      Phronomy.configure { |c| c.tracer = original }
    end

    [StreamingBasicAgent, StreamingReactAgent].each do |klass|
      it "creates a span named agent.stream for #{klass}" do
        klass.new(on_event: ->(_event) {}).stream("hello")
        expect(recording_tracer.spans.map { |span| span[:name] })
          .to include("agent.stream")
      end
    end
  end

  describe "stream queue configuration" do
    it "does not expose the obsolete stream_queue_max_size setting" do
      expect(Phronomy.configuration).not_to respond_to(:stream_queue_max_size)
      expect(Phronomy.configuration).not_to respond_to(:stream_queue_max_size=)
    end
  end
end
