# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent terminal stream callback error policy" do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-69", version: 1
      instructions "test"
      model "gpt-4o-mini"
    end
  end
  let(:result) { {output: "completed", messages: [], usage: nil} }
  let(:logger) { double("logger", warn: nil) }

  after do
    Phronomy.reset_configuration!
    Phronomy.reset_runtime!
  rescue
    nil
  end

  describe Phronomy::Configuration do
    it "defaults stream_callback_error_policy to :report" do
      expect(described_class.new.stream_callback_error_policy).to eq(:report)
    end

    it "accepts :report and :fail_task" do
      config = described_class.new
      config.stream_callback_error_policy = :report
      expect(config.stream_callback_error_policy).to eq(:report)
      config.stream_callback_error_policy = :fail_task
      expect(config.stream_callback_error_policy).to eq(:fail_task)
    end

    it "rejects unsupported values" do
      config = described_class.new
      expect { config.stream_callback_error_policy = :raise }
        .to raise_error(Phronomy::ConfigurationError, /report.*fail_task/)
      expect { config.stream_callback_error_policy = nil }
        .to raise_error(Phronomy::ConfigurationError)
    end
  end

  describe Phronomy::StreamCallbackError do
    it "is a Phronomy error with delivery context" do
      original_error = RuntimeError.new("callback failed")
      wrapped = described_class.new(
        event_type: :done,
        original_error: original_error,
        result: result
      )
      expect(wrapped).to be_a(Phronomy::Error)
      expect(wrapped.event_type).to eq(:done)
      expect(wrapped.result).to equal(result)
      expect(wrapped.original_error).to equal(original_error)
      expect(wrapped.message).to include(":done", "RuntimeError", "callback failed")
    end
  end

  describe "terminal completion handling via Agent-incarnation listener" do
    let(:fake_tokens) do
      double(
        "Tok",
        input: 1,
        output: 2,
        cached: 0,
        cache_creation: 0,
        to_h: {"input" => 1, "output" => 2, "cached" => 0, "cache_creation" => 0}
      )
    end
    let(:fake_response) do
      double(
        "Resp",
        role: :assistant,
        content: "completed",
        tool_calls: nil,
        tokens: fake_tokens,
        tool_call?: false
      )
    end

    def build_streaming_chat_for_policy(response)
      dbl = double("Chat")
      allow(dbl).to receive(:with_instructions).and_return(dbl)
      allow(dbl).to receive(:with_tool).and_return(dbl)
      allow(dbl).to receive(:with_temperature).and_return(dbl)
      allow(dbl).to receive(:messages).and_return([response])
      allow(dbl).to receive(:cancellation_token=)
      allow(dbl).to receive(:on_tool_call)
      allow(dbl).to receive(:before_tool_call)
      allow(dbl).to receive(:on_tool_result)
      allow(dbl).to receive(:ask) do |_msg, &blk|
        blk&.call(double("Chunk", content: "token1"))
        response
      end
      allow(dbl).to receive(:complete) do |&blk|
        blk&.call(double("Chunk", content: "token1"))
        response
      end
      dbl
    end

    before do
      allow(RubyLLM).to receive(:chat)
        .and_return(build_streaming_chat_for_policy(fake_response))
      Phronomy.configuration.logger = logger
    end

    it "reports a :done callback failure and preserves the result under :report" do
      callback_error = RuntimeError.new("websocket disconnected")
      events = []
      expect(logger).to receive(:warn).with(
        include("Stream callback failed", "event=:done", "policy=:report", "websocket disconnected")
      )
      agent = agent_class.new(
        on_event: ->(event) {
          events << event.type
          raise callback_error if event.type == :done
        }
      )
      result = agent.stream_async("hello").wait_result
      expect(result[:output]).to eq("completed")
      expect(events).to include(:done)
    end

    it "fails the Task with StreamCallbackError under :fail_task" do
      Phronomy.configuration.stream_callback_error_policy = :fail_task
      callback_error = RuntimeError.new("delivery failed")
      events = []
      agent = agent_class.new(
        on_event: ->(event) {
          events << event.type
          raise callback_error if event.type == :done
        }
      )
      task = agent.stream_async("hello")
      expect { task.wait_result }.to raise_error(Phronomy::StreamCallbackError) { |error|
        expect(error.event_type).to eq(:done)
        expect(error.original_error).to equal(callback_error)
        expect(error.result[:output]).to eq("completed")
      }
      expect(events).to include(:done)
    end

    it "keeps the original Agent error when the :error callback also fails" do
      bad_chat = build_streaming_chat_for_policy(fake_response)
      allow(bad_chat).to receive(:ask)
        .and_raise(Phronomy::TransportError, "provider failed")
      allow(bad_chat).to receive(:complete)
        .and_raise(Phronomy::TransportError, "provider failed")
      allow(RubyLLM).to receive(:chat).and_return(bad_chat)

      callback_error = RuntimeError.new("error sink failed")
      expect(logger).to receive(:warn).with(include("event=:error"))
      agent = agent_class.new(
        on_event: ->(event) {
          raise callback_error if event.type == :error
        }
      )
      expect { agent.stream_async("hello").wait_result }
        .to raise_error(Phronomy::TransportError, "provider failed")
    end

    it "uses Kernel.warn as fallback when the configured logger fails" do
      failing_logger = double("failing_logger")
      allow(failing_logger).to receive(:warn).and_raise("logger failed")
      Phronomy.configuration.logger = failing_logger
      allow(Kernel).to receive(:warn)
      expect(Kernel).to receive(:warn).with(
        include("Logger failed while reporting a stream callback error")
      )
      agent = agent_class.new(
        on_event: ->(event) {
          raise "callback failed" if event.type == :done
        }
      )
      expect(agent.stream_async("hello").wait_result[:output]).to eq("completed")
    end

    it "rejects the removed per-invocation stream listener" do
      agent = agent_class.new(on_event: ->(_event) {})
      expect {
        agent.stream_async("hello", on_event: ->(_event) {})
      }.to raise_error(ArgumentError, /removed per-invocation/)
      expect {
        agent.stream_async("hello") { |_event| }
      }.to raise_error(ArgumentError, /no longer register Agent events/)
    end
  end
end
