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
  let(:agent) { agent_class.new }
  let(:event_loop) { double("event_loop", current?: true) }
  let(:invocation) { double("invocation", id: "invocation-1") }
  let(:result) { {output: "completed", messages: [], usage: nil} }
  let(:logger) { double("logger", warn: nil) }

  after do
    Phronomy.reset_configuration!
  end

  def deferred_result_task(name = "stream-callback-policy-test")
    Phronomy::Task.deferred(name: name)
  end

  def handle_completion(
    invocation:, listener:, event_loop:, callback_error_policy:, result_task: deferred_result_task,
    error: nil,
    mode: :stream
  )
    agent.send(
      :_handle_agent_completion,
      result_task: result_task,
      invocation: invocation,
      error: error,
      mode: mode,
      listener: listener,
      event_loop: event_loop,
      callback_error_policy: callback_error_policy
    )
    result_task
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

      expect do
        config.stream_callback_error_policy = :raise
      end.to raise_error(
        Phronomy::ConfigurationError,
        /stream_callback_error_policy.*report.*fail_task/
      )

      expect do
        config.stream_callback_error_policy = nil
      end.to raise_error(Phronomy::ConfigurationError)
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
      expect(wrapped.message).to include(":done")
      expect(wrapped.message).to include("RuntimeError")
      expect(wrapped.message).to include("callback failed")
    end
  end

  describe "terminal completion handling via real pipeline" do
    # Streaming agent with a mock LLM that returns a single chunk then completes.
    let(:streaming_agent) { agent_class.new }
    let(:fake_tokens) { double("Tok", input: 1, output: 2, cached: 0, cache_creation: 0, to_h: {"input" => 1, "output" => 2, "cached" => 0, "cache_creation" => 0}) }
    let(:fake_response) { double("Resp", role: :assistant, content: "completed", tool_calls: nil, tokens: fake_tokens, tool_call?: false) }

    def build_streaming_chat_for_policy(response)
      dbl = double("Chat")
      allow(dbl).to receive(:with_instructions).and_return(dbl)
      allow(dbl).to receive(:with_tool).and_return(dbl)
      allow(dbl).to receive(:with_temperature).and_return(dbl)
      allow(dbl).to receive(:messages).and_return([response])
      allow(dbl).to receive(:cancellation_token=)
      allow(dbl).to receive(:on_tool_call)
      allow(dbl).to receive(:on_tool_result)
      allow(dbl).to receive(:ask) { |_msg, &blk|
        blk&.call(double("Chunk", content: "token1"))
        response
      }
      allow(dbl).to receive(:complete) { |&blk|
        blk&.call(double("Chunk", content: "token1"))
        response
      }
      dbl
    end

    before do
      allow(RubyLLM).to receive(:chat).and_return(build_streaming_chat_for_policy(fake_response))
      Phronomy.configuration.logger = logger
    end

    it "reports a :done callback failure and preserves the Agent result by default (:report)" do
      callback_error = RuntimeError.new("websocket disconnected")
      events = []
      expect(logger).to receive(:warn).with(
        include("Stream callback failed", "event=:done", "policy=:report", "websocket disconnected")
      )

      task = streaming_agent.stream_async("hello", on_event: ->(event) {
        events << event.type
        raise callback_error if event.type == :done
      })
      result = task.wait_result
      expect(result[:output]).to eq("completed")
      expect(events).to include(:done)
    end

    it "fails the Task with StreamCallbackError under :fail_task" do
      Phronomy.configuration.stream_callback_error_policy = :fail_task
      callback_error = RuntimeError.new("delivery failed")
      events = []

      task = streaming_agent.stream_async("hello", on_event: ->(event) {
        events << event.type
        raise callback_error if event.type == :done
      })

      expect { task.wait_result }.to raise_error(Phronomy::StreamCallbackError) { |error|
        expect(error.event_type).to eq(:done)
        expect(error.original_error).to equal(callback_error)
        expect(error.result[:output]).to eq("completed")
      }
      expect(events).to include(:done)
    end

    it "keeps the original Agent error when the :error callback also fails" do
      # Simulate an LLM failure by making ask raise.
      allow(RubyLLM).to receive(:chat).and_return(
        build_streaming_chat_for_policy(fake_response).tap do |dbl|
          allow(dbl).to receive(:ask).and_raise(Phronomy::TransportError, "provider failed")
        end
      )

      callback_error = RuntimeError.new("error sink failed")
      expect(logger).to receive(:warn).with(include("event=:error"))

      task = streaming_agent.stream_async("hello", on_event: ->(event) {
        raise callback_error if event.type == :error
      })

      expect { task.wait_result }.to raise_error(Phronomy::TransportError, "provider failed")
    end

    it "uses Kernel.warn as a fallback when the configured logger fails" do
      failing_logger = double("failing_logger")
      allow(failing_logger).to receive(:warn).and_raise("logger failed")
      Phronomy.configuration.logger = failing_logger
      allow(Kernel).to receive(:warn)
      expect(Kernel).to receive(:warn).with(
        include("Logger failed while reporting a stream callback error")
      )

      task = streaming_agent.stream_async("hello", on_event: ->(event) {
        raise "callback failed" if event.type == :done
      })
      task.wait_result
    end
  end

  describe "public async entry points" do
    let(:streaming_agent) { agent_class.new }
    let(:fake_tokens) { double("Tok2", input: 1, output: 2, cached: 0, cache_creation: 0, to_h: {"input" => 1, "output" => 2, "cached" => 0, "cache_creation" => 0}) }
    let(:fake_response) { double("Resp2", role: :assistant, content: "completed", tool_calls: nil, tokens: fake_tokens, tool_call?: false) }

    def build_streaming_chat_for_entry(response)
      dbl = double("Chat2")
      allow(dbl).to receive(:with_instructions).and_return(dbl)
      allow(dbl).to receive(:with_tool).and_return(dbl)
      allow(dbl).to receive(:with_temperature).and_return(dbl)
      allow(dbl).to receive(:messages).and_return([response])
      allow(dbl).to receive(:cancellation_token=)
      allow(dbl).to receive(:on_tool_call)
      allow(dbl).to receive(:on_tool_result)
      allow(dbl).to receive(:ask) { |_msg, &blk|
        blk&.call(double("Chunk2", content: "token"))
        response
      }
      allow(dbl).to receive(:complete) { |&blk|
        blk&.call(double("Chunk2", content: "token"))
        response
      }
      dbl
    end

    before { allow(RubyLLM).to receive(:chat).and_return(build_streaming_chat_for_entry(fake_response)) }

    it "applies :fail_task for the initial stream execution" do
      Phronomy.configuration.stream_callback_error_policy = :fail_task
      callback_error = RuntimeError.new("terminal consumer failed")

      task = streaming_agent.stream_async("hello") do |event|
        raise callback_error if event.type == :done
      end

      expect { task.wait_result }.to raise_error(Phronomy::StreamCallbackError) { |error|
        expect(error.original_error).to equal(callback_error)
        expect(error.event_type).to eq(:done)
      }
    end
  end
end
