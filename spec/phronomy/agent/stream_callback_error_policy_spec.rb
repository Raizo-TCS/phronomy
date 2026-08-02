# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent terminal stream callback error policy" do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
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

  describe "terminal completion handling" do
    before do
      Phronomy.configuration.logger = logger
    end

    it "reports a :done callback failure and preserves the Agent result by default" do
      callback_error = RuntimeError.new("websocket disconnected")
      event_types = []
      listener = lambda do |event|
        event_types << event.type
        raise callback_error
      end
      allow(agent).to receive(:_extract_invoke_result)
        .with(invocation)
        .and_return(result)
      expect(logger).to receive(:warn).with(
        include(
          "Stream callback failed",
          "event=:done",
          "agent_invocation_id=invocation-1",
          "policy=:report",
          "RuntimeError: websocket disconnected"
        )
      )

      task = handle_completion(
        invocation: invocation,
        listener: listener,
        event_loop: event_loop,
        callback_error_policy: :report
      )

      expect(task.wait_result).to equal(result)
      expect(event_types).to eq([:done])
    end

    it "fails the Task with StreamCallbackError under :fail_task" do
      callback_error = RuntimeError.new("delivery failed")
      event_types = []
      listener = lambda do |event|
        event_types << event.type
        raise callback_error
      end
      allow(agent).to receive(:_extract_invoke_result)
        .with(invocation)
        .and_return(result)

      task = handle_completion(
        invocation: invocation,
        listener: listener,
        event_loop: event_loop,
        callback_error_policy: :fail_task
      )

      expect do
        task.wait_result
      end.to raise_error(Phronomy::StreamCallbackError) { |error|
        expect(error.event_type).to eq(:done)
        expect(error.result).to equal(result)
        expect(error.original_error).to equal(callback_error)
        expect(error.cause).to equal(callback_error)
      }
      expect(event_types).to eq([:done])
    end

    it "retains a suspended result when :approval_required delivery fails" do
      request = double("approval_request")
      suspended_result = {
        suspended: true,
        agent_invocation_id: "invocation-1",
        approval_request: request,
        messages: []
      }
      callback_error = RuntimeError.new("dialog failed")
      event_types = []
      listener = lambda do |event|
        event_types << event.type
        raise callback_error
      end
      allow(agent).to receive(:_extract_invoke_result)
        .with(invocation)
        .and_return(suspended_result)

      task = handle_completion(
        invocation: invocation,
        listener: listener,
        event_loop: event_loop,
        callback_error_policy: :fail_task
      )

      expect do
        task.wait_result
      end.to raise_error(Phronomy::StreamCallbackError) { |error|
        expect(error.event_type).to eq(:approval_required)
        expect(error.result).to equal(suspended_result)
        expect(error.result[:approval_request]).to be(request)
      }
      expect(event_types).to eq([:approval_required])
    end

    it "keeps the original Agent error when the :error callback also fails" do
      execution_error = Phronomy::TransportError.new("provider failed")
      callback_error = RuntimeError.new("error sink failed")
      event_types = []
      listener = lambda do |event|
        event_types << event.type
        raise callback_error
      end
      expect(logger).to receive(:warn).with(
        include(
          "event=:error",
          "RuntimeError: error sink failed"
        )
      )

      task = handle_completion(
        invocation: nil,
        error: execution_error,
        listener: listener,
        event_loop: event_loop,
        callback_error_policy: :fail_task
      )

      expect do
        task.wait_result
      end.to raise_error(Phronomy::TransportError, "provider failed") { |error|
        expect(error).to equal(execution_error)
      }
      expect(event_types).to eq([:error])
    end

    it "does not invoke the listener outside the EventLoop" do
      outside_loop = double("event_loop", current?: false)
      listener = double("listener")
      expect(listener).not_to receive(:call)

      task = handle_completion(
        invocation: invocation,
        listener: listener,
        event_loop: outside_loop,
        callback_error_policy: :report
      )

      expect do
        task.wait_result
      end.to raise_error(Phronomy::Error, /outside the EventLoop/)
    end

    it "uses Kernel.warn as a fallback when the configured logger fails" do
      failing_logger = double("logger")
      allow(failing_logger).to receive(:warn).and_raise("logger failed")
      Phronomy.configuration.logger = failing_logger
      allow(Kernel).to receive(:warn)
      expect(Kernel).to receive(:warn).with(
        include("Logger failed while reporting a stream callback error")
      )
      allow(agent).to receive(:_extract_invoke_result)
        .with(invocation)
        .and_return(result)

      task = handle_completion(
        invocation: invocation,
        listener: ->(_event) { raise "callback failed" },
        event_loop: event_loop,
        callback_error_policy: :report
      )

      expect(task.wait_result).to equal(result)
    end
  end

  describe "public async entry points" do
    before do
      Phronomy.configuration.logger = logger
    end

    it "snapshots :fail_task for the initial stream execution" do
      session = double("session")
      runtime = double("runtime", event_loop: event_loop)
      completed_invocation = double("completed_invocation", id: "invocation-1")
      callback_error = RuntimeError.new("terminal consumer failed")

      allow(Phronomy::Runtime).to receive(:instance).and_return(runtime)
      allow(Phronomy::Agent::AgentInvocationSessionBuilder)
        .to receive(:build)
        .and_return(session)
      allow(agent).to receive(:_extract_invoke_result)
        .with(completed_invocation)
        .and_return(result)
      allow(event_loop).to receive(:register) do |_session, completion:|
        completion.backend.unblock(completed_invocation, nil)
        completion.transition!(:completed, value: completed_invocation)
        completion
      end

      Phronomy.configuration.stream_callback_error_policy = :fail_task
      task = agent.stream_async("hi") do |_event|
        Phronomy.configuration.stream_callback_error_policy = :report
        raise callback_error
      end

      expect do
        task.wait_result
      end.to raise_error(Phronomy::StreamCallbackError) { |error|
        expect(error.original_error).to equal(callback_error)
      }
    end

    it "applies :fail_task after approve_async resumes a streaming invocation" do
      parent_session = double("parent_session")
      runtime = double("runtime", event_loop: event_loop)
      callback_error = RuntimeError.new("resumed delivery failed")
      listener = ->(_event) { raise callback_error }
      resumed_invocation = double(
        "resumed_invocation",
        id: "invocation-1",
        event_listener: listener,
        mode: :stream,
        tool_invocations: []
      )
      allow(resumed_invocation).to receive(:merge_config!)
      allow(resumed_invocation).to receive(:begin_approval_resume!)

      entry = double("registry_entry", invocation: resumed_invocation)
      allow(Phronomy::Agent::AgentInvocationRegistry)
        .to receive(:consume_approval)
        .with("invocation-1", "request-1")
        .and_return(entry)
      allow(Phronomy::Runtime).to receive(:instance).and_return(runtime)
      allow(Phronomy::Agent::AgentInvocationSessionBuilder)
        .to receive(:build_for_resume)
        .and_return(parent_session)
      allow(agent).to receive(:_extract_invoke_result)
        .with(resumed_invocation)
        .and_return(result)
      allow(event_loop).to receive(:register) do |_session, completion:|
        completion.backend.unblock(resumed_invocation, nil)
        completion.transition!(:completed, value: resumed_invocation)
        completion
      end

      Phronomy.configuration.stream_callback_error_policy = :fail_task
      task = agent.approve_async(
        "invocation-1",
        approval_request_id: "request-1"
      )

      expect do
        task.wait_result
      end.to raise_error(Phronomy::StreamCallbackError) { |error|
        expect(error.event_type).to eq(:done)
        expect(error.result).to equal(result)
        expect(error.original_error).to equal(callback_error)
      }
    end
  end
end
