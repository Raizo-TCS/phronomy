# frozen_string_literal: true

require "spec_helper"

RSpec.describe "D02-F03 automatic tracing coverage" do
  let(:root) { File.expand_path("../../..", __dir__) }
  let(:recorded_spans) { [] }

  let(:recording_tracer) do
    spans = recorded_spans
    Class.new(Phronomy::Tracing::Base) do
      define_method(:start_span) do |name, input: nil, **metadata|
        span = {
          name: name,
          input: input,
          metadata: metadata,
          output: nil,
          usage: nil,
          error: nil
        }
        spans << span
        span
      end

      define_method(:finish_span) do |span, output: nil, usage: nil, error: nil|
        span[:output] = output
        span[:usage] = usage
        span[:error] = error
        nil
      end
    end.new
  end

  after { Phronomy.reset_configuration! }

  it "redacts automatic-span payloads and sensitive error detail when trace_pii is false" do
    Phronomy.configure do |config|
      config.tracer = recording_tracer
      config.trace_pii = false
    end

    error = RuntimeError.new("secret exception payload")
    error.set_backtrace(["/secret/path.rb:1"])

    handle = Phronomy::Tracing::Automatic.start(
      "llm.call",
      input: "secret prompt",
      agent_id: "agent-1",
      execution_id: "execution-1",
      llm_call_id: "llm-1",
      task_id: "task-1",
      user_id: "private-user",
      session_id: "private-session"
    )
    Phronomy::Tracing::Automatic.finish(
      handle,
      output: "secret response",
      error: error
    )

    span = recorded_spans.fetch(0)
    expect(span[:input]).to eq("[REDACTED]")
    expect(span[:output]).to eq("[REDACTED]")
    expect(span[:metadata]).to include(
      agent_id: "agent-1",
      execution_id: "execution-1",
      llm_call_id: "llm-1",
      task_id: "task-1"
    )
    expect(span[:metadata]).not_to have_key(:user_id)
    expect(span[:metadata]).not_to have_key(:session_id)
    expect(span[:error]).to be_a(RuntimeError)
    expect(span[:error].message).to eq("[REDACTED]")
    expect(span[:error].backtrace).to eq([])
  end

  it "passes automatic-span payloads through when trace_pii is true" do
    Phronomy.configure do |config|
      config.tracer = recording_tracer
      config.trace_pii = true
    end

    error = RuntimeError.new("visible failure")
    handle = Phronomy::Tracing::Automatic.start(
      "tool.execute",
      input: {"secret" => "visible"},
      agent_id: "agent-2",
      execution_id: "execution-2",
      tool_invocation_id: "tool-2",
      user_id: "visible-user"
    )
    Phronomy::Tracing::Automatic.finish(
      handle,
      output: "visible output",
      error: error
    )

    span = recorded_spans.fetch(0)
    expect(span[:input]).to eq({"secret" => "visible"})
    expect(span[:output]).to eq("visible output")
    expect(span[:metadata][:user_id]).to eq("visible-user")
    expect(span[:error]).to equal(error)
  end

  it "observes a Task without changing its result" do
    Phronomy.configure do |config|
      config.tracer = recording_tracer
      config.trace_pii = false
    end

    task = Phronomy::Task.deferred(name: "automatic-tracing-test")
    usage = Phronomy::TokenUsage.new(input: 3, output: 4)
    Phronomy::Tracing::Automatic.observe_task(
      task,
      "agent.execution",
      input: "secret input",
      agent_id: "agent-3",
      execution_id: "execution-3",
      mode: :invoke
    )

    result = {output: "secret output", usage: usage}.freeze
    task.complete(result)

    expect(task.wait_result).to equal(result)
    span = recorded_spans.fetch(0)
    expect(span[:name]).to eq("agent.execution")
    expect(span[:output]).to eq("[REDACTED]")
    expect(span[:usage]).to equal(usage)
  end

  it "does not change an operation result when automatic tracing start fails" do
    logger = double("logger", warn: nil)
    tracer = Class.new(Phronomy::Tracing::Base) do
      def start_span(*) = raise("start failed")
      def finish_span(*) = nil
    end.new

    Phronomy.configure do |config|
      config.tracer = tracer
      config.logger = logger
      config.trace_pii = false
    end

    result = Phronomy::Tracing::Automatic.trace("agent.execution") { "ok" }
    expect(result).to eq("ok")
    expect(logger).to have_received(:warn).with(/automatic tracing start failed/)
  end

  it "does not change an operation result when automatic tracing finish fails" do
    logger = double("logger", warn: nil)
    tracer = Class.new(Phronomy::Tracing::Base) do
      def start_span(*) = Object.new
      def finish_span(*) = raise("finish failed")
    end.new

    Phronomy.configure do |config|
      config.tracer = tracer
      config.logger = logger
      config.trace_pii = false
    end

    result = Phronomy::Tracing::Automatic.trace("multi_agent.turn") { "ok" }
    expect(result).to eq("ok")
    expect(logger).to have_received(:warn).with(/automatic tracing finish failed/)
  end

  it "keeps automatic coverage on logical operations instead of blocking facade wrappers" do
    async_api = File.read(File.join(root, "lib/phronomy/agent/async_event_api.rb"))
    coordinator = File.read(File.join(root, "lib/phronomy/agent/execution_coordinator.rb"))
    llm = File.read(File.join(root, "lib/phronomy/agent/agent_invocation_session_builder.rb"))
    tool = File.read(File.join(root, "lib/phronomy/agent/tool_invocation.rb"))
    workflow = File.read(File.join(root, "lib/phronomy/workflow_runner.rb"))
    multi = File.read(File.join(root, "lib/phronomy/multi_agent/runner.rb"))

    expect(async_api).not_to include('trace("agent.invoke"')
    expect(async_api).not_to include('trace("agent.stream"')
    expect(workflow).not_to include('trace("workflow.invoke"')

    expect(coordinator).to include('"agent.execution"')
    expect(llm).to include('"llm.call"')
    expect(tool).to include('"tool.execute"')
    expect(workflow).to include('"workflow.execution"')
    expect(multi).to include('"multi_agent.turn"')
  end

  it "removes the unused InvocationContext tracer_span API without adding a replacement trace context" do
    invocation_context =
      File.read(File.join(root, "lib/phronomy/invocation_context.rb"))
    runtime_rbs = File.read(File.join(root, "sig/phronomy/runtime.rbs"))
    api_snapshot =
      File.read(File.join(root, "spec/fixtures/api_snapshot.json"))
    automatic =
      File.read(File.join(root, "lib/phronomy/tracing/automatic.rb"))

    expect(invocation_context).not_to include("tracer_span")
    expect(runtime_rbs).not_to include("tracer_span")
    expect(api_snapshot).not_to include('"tracer_span"')
    expect(automatic).not_to include("SpanContext")
    expect(automatic).not_to include("parent_span:")
    expect(automatic).not_to include("trace_parent:")
  end
end
