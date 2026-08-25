# frozen_string_literal: true

require "spec_helper"

class SymmetricAsyncEventAgent < Phronomy::Agent::Base
  agent_definition id: "symmetric-async-event-agent", version: 1
  model "test-model"
  instructions "Return a short answer."
end

RSpec.describe "Agent async event contract" do
  let(:fake_tokens) do
    double(
      "Tokens",
      input: 3,
      output: 2,
      cached: 0,
      cache_creation: 0,
      to_h: {input: 3, output: 2, cached: 0, cache_creation: 0}
    )
  end

  let(:fake_response) do
    double(
      "Response",
      role: :assistant,
      content: "answer",
      tool_calls: nil,
      tokens: fake_tokens,
      tool_call?: false
    )
  end

  def build_chat(response)
    chat = double("Chat")
    allow(chat).to receive(:with_instructions).and_return(chat)
    allow(chat).to receive(:with_tool).and_return(chat)
    allow(chat).to receive(:with_temperature).and_return(chat)
    allow(chat).to receive(:cancellation_token=)
    allow(chat).to receive(:messages).and_return([response])
    allow(chat).to receive(:on_tool_call)
    allow(chat).to receive(:before_tool_call)
    allow(chat).to receive(:on_tool_result)
    allow(chat).to receive(:ask) do |_message, &block|
      block&.call(double("Chunk", content: "answer"))
      response
    end
    allow(chat).to receive(:complete) do |&block|
      block&.call(double("Chunk", content: "answer"))
      response
    end
    chat
  end

  before do
    allow(RubyLLM).to receive(:chat)
      .and_return(build_chat(fake_response))
  end

  after do
    Phronomy.reset_runtime!
  rescue
    nil
  end

  it "delivers lifecycle events from invoke_async through the Agent-incarnation listener" do
    events = []
    agent = SymmetricAsyncEventAgent.new(
      on_event: ->(event) { events << event.type }
    )
    result = agent.invoke_async("hello").wait_result

    expect(result[:output]).to eq("answer")
    expect(events).to eq([:done])
  end

  it "accepts an event listener block at Agent materialization" do
    events = []
    agent = SymmetricAsyncEventAgent.new do |event|
      events << event.type
    end
    result = agent.invoke_async("hello").wait_result

    expect(result[:output]).to eq("answer")
    expect(events).to eq([:done])
  end

  it "keeps invoke_async listener optional" do
    result = SymmetricAsyncEventAgent.new.invoke_async("hello").wait_result
    expect(result[:output]).to eq("answer")
  end

  it "rejects the removed per-invocation listener keyword and block" do
    agent = SymmetricAsyncEventAgent.new
    expect {
      agent.invoke_async("hello", on_event: ->(_event) {})
    }.to raise_error(ArgumentError, /removed per-invocation/)

    expect {
      agent.invoke_async("hello") { |_event| }
    }.to raise_error(ArgumentError, /no longer register Agent events/)
  end

  it "adds token events only for stream_async" do
    invoke_events = []
    stream_events = []

    SymmetricAsyncEventAgent.new(
      on_event: ->(event) { invoke_events << event.type }
    ).invoke_async("hello").wait_result

    SymmetricAsyncEventAgent.new(
      on_event: ->(event) { stream_events << event.type }
    ).stream_async("hello").wait_result

    expect(invoke_events).to eq([:done])
    expect(stream_events).to include(:token)
    expect(stream_events.last).to eq(:done)
  end

  it "requires a live Agent listener for stream/stream_async" do
    agent = SymmetricAsyncEventAgent.new
    expect { agent.stream_async("hello") }
      .to raise_error(ArgumentError, /Agent on_event listener/)
    expect { agent.stream("hello") }
      .to raise_error(ArgumentError, /Agent on_event listener/)
  end

  it "runs invoke_async and stream_async listeners on the EventLoop thread" do
    caller_thread = Thread.current
    event_loop = Phronomy::Runtime.instance.event_loop

    [:invoke_async, :stream_async].each do |method_name|
      callback_threads = []
      on_event_loop = []
      agent = SymmetricAsyncEventAgent.new(
        on_event: ->(_event) {
          callback_threads << Thread.current
          on_event_loop << event_loop.current?
        }
      )
      agent.public_send(method_name, "hello").wait_result

      expect(callback_threads).not_to be_empty
      expect(callback_threads).to all(satisfy { |thread| thread != caller_thread })
      expect(on_event_loop).to all(be(true))
    end
  end

  it "delivers shared tool events independently of streaming mode" do
    [:invoke, :stream].each do |mode|
      event_types = []
      invocation = Phronomy::Agent::AgentInvocation.new(
        agent: SymmetricAsyncEventAgent.new,
        input: "hello",
        config: {},
        event_listener: ->(event) { event_types << event.type },
        mode: mode
      )
      invocation.chat = double("Chat", messages: [])
      tool_call = double("ToolCall")

      invocation.accept_tool_calls!([tool_call])
      expect(event_types).to eq([:tool_call])
    end
  end

  it "delivers shared tool-result events independently of streaming mode" do
    [:invoke, :stream].each do |mode|
      event_types = []
      chat = double("Chat", messages: [])
      allow(chat).to receive(:add_message)
      invocation = Phronomy::Agent::AgentInvocation.new(
        agent: SymmetricAsyncEventAgent.new,
        input: "hello",
        config: {},
        event_listener: ->(event) { event_types << event.type },
        mode: mode
      )
      invocation.chat = chat
      invocation.tool_invocations = [
        double(
          "ToolInvocation",
          result: "tool output",
          tool_call_id: "call-1",
          tool_name: "lookup"
        )
      ]

      invocation.record_tool_results!
      expect(event_types).to eq([:tool_result])
    end
  end

  it "delivers :error before failing invoke_async" do
    bad_chat = build_chat(fake_response)
    allow(bad_chat).to receive(:ask).and_raise(RuntimeError, "LLM exploded")
    allow(bad_chat).to receive(:complete).and_raise(RuntimeError, "LLM exploded")
    allow(RubyLLM).to receive(:chat).and_return(bad_chat)

    events = []
    agent = SymmetricAsyncEventAgent.new(
      on_event: ->(event) { events << event.type }
    )
    task = agent.invoke_async("hello")

    expect { task.wait_result }.to raise_error(RuntimeError, "LLM exploded")
    expect(events.last).to eq(:error)
  end

  it "delivers :error before failing stream_async" do
    bad_chat = build_chat(fake_response)
    allow(bad_chat).to receive(:ask).and_raise(RuntimeError, "LLM exploded")
    allow(bad_chat).to receive(:complete).and_raise(RuntimeError, "LLM exploded")
    allow(RubyLLM).to receive(:chat).and_return(bad_chat)

    events = []
    agent = SymmetricAsyncEventAgent.new(
      on_event: ->(event) { events << event.type }
    )
    task = agent.stream_async("hello")

    expect { task.wait_result(timeout: 2) }
      .to raise_error(RuntimeError, "LLM exploded")
    expect(events.last).to eq(:error)
  end

  it "distinguishes timeout from explicit cancellation" do
    timeout_events = []
    timeout_agent = SymmetricAsyncEventAgent.new(
      on_event: ->(event) { timeout_events << event.type }
    )
    timeout_task = timeout_agent.invoke_async(
      "hello",
      config: {
        cancellation_token:
          Phronomy::Concurrency::CancellationToken.timeout_after(-1)
      }
    )

    expect { timeout_task.wait_result }.to raise_error(Phronomy::TimeoutError)
    expect(timeout_events).to eq([:timeout])

    token = Phronomy::Concurrency::CancellationToken.new
    token.cancel!
    cancellation_events = []
    cancellation_agent = SymmetricAsyncEventAgent.new(
      on_event: ->(event) { cancellation_events << event.type }
    )
    cancellation_task = cancellation_agent.invoke_async(
      "hello",
      config: {cancellation_token: token}
    )

    expect { cancellation_task.wait_result }
      .to raise_error(Phronomy::CancellationError)
    expect(cancellation_events).to eq([:cancelled])
  end

  it "delivers the terminal event before settling the returned Task" do
    order = []
    agent = SymmetricAsyncEventAgent.new(
      on_event: ->(event) {
        order << event.type if event.type == :done
      }
    )
    task = agent.invoke_async("hello")
    task.on_complete { |_value, _error| order << :task_completed }

    task.wait_result
    expect(order).to eq([:done, :task_completed])
  end

  it "keeps Task#on_complete active when the Agent listener is configured" do
    callback_result = Queue.new
    agent = SymmetricAsyncEventAgent.new(on_event: ->(_event) {})
    task = agent.invoke_async("hello")
    task.on_complete do |value, error|
      callback_result << [value, error]
    end

    value, error = callback_result.pop
    expect(error).to be_nil
    expect(value[:output]).to eq("answer")
    expect(task.wait_result[:output]).to eq("answer")
  end

  it "passes tracing InvocationContext without generic identity" do
    ic = Phronomy::InvocationContext.new(task_id: "ctx-task")
    captured_config = nil
    allow(Phronomy::Agent::AgentInvocationSessionBuilder)
      .to receive(:build)
      .and_wrap_original do |original, **kwargs|
        captured_config = kwargs[:config]
        original.call(**kwargs)
      end
    events = []
    agent = SymmetricAsyncEventAgent.new(
      on_event: ->(event) { events << event.type }
    )
    result = agent.invoke_async(
      "hello",
      invocation_context: ic
    ).wait_result
    expect(result[:output]).to eq("answer")
    expect(events).to eq([:done])
    expect(captured_config).to include(invocation_context: ic)
    expect(captured_config).not_to have_key(:thread_id)
    expect(captured_config).not_to have_key(:session_id)
  end

  it "passes tracing InvocationContext through stream APIs" do
    [:stream_async, :stream].each do |method_name|
      ic = Phronomy::InvocationContext.new(task_id: "ctx-#{method_name}")
      events = []
      agent = SymmetricAsyncEventAgent.new(
        on_event: ->(event) { events << event.type }
      )
      result = agent.public_send(
        method_name,
        "hello",
        invocation_context: ic
      )
      result.wait_result if result.is_a?(Phronomy::Task)
      expect(events).to include(:done)
    end
  end

  it "rejects on_event plus a construction block" do
    expect {
      SymmetricAsyncEventAgent.new(
        on_event: ->(_event) {}
      ) { |_event| }
    }.to raise_error(ArgumentError, /on_event.*block|block.*on_event/i)
  end
end

RSpec.describe "Agent::Base#check_cancellation!" do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) {
      agent_definition id: "test-agent-201", version: 1
    }
  end
  let(:agent) { agent_class.new }

  def check(config)
    agent.send(:check_cancellation!, config)
    nil
  rescue => e
    e
  end

  it "returns nil when no cancellation token is set" do
    expect(check({})).to be_nil
  end

  it "returns nil when token is not cancelled" do
    token = Phronomy::Concurrency::CancellationToken.new
    expect(check({cancellation_token: token})).to be_nil
  end

  it "raises CancellationError on explicit cancel" do
    token = Phronomy::Concurrency::CancellationToken.new
    token.cancel!
    expect(check({cancellation_token: token})).to be_a(Phronomy::CancellationError)
  end

  it "raises TimeoutError when wall-clock deadline has expired" do
    token = Phronomy::Concurrency::CancellationToken.timeout_after(-1)
    result = check({cancellation_token: token})
    expect(result).to be_a(Phronomy::TimeoutError)
    expect(result.message).to eq("invocation cancelled")
  end

  it "raises TimeoutError for monotonic deadline token (timeout_after)" do
    token = Phronomy::Concurrency::CancellationToken.timeout_after(-1)
    expect(check({cancellation_token: token})).to be_a(Phronomy::TimeoutError)
  end

  it "preserves a custom message" do
    token = Phronomy::Concurrency::CancellationToken.timeout_after(-1)
    result = agent.send(:check_cancellation!, {cancellation_token: token}, "stopped")
    expect(result).to be_nil
  rescue => e
    expect(e).to be_a(Phronomy::TimeoutError)
    expect(e.message).to eq("stopped")
  end
end
