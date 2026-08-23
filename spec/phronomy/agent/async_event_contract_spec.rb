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

  it "delivers lifecycle events from invoke_async" do
    events = []
    result = SymmetricAsyncEventAgent.new.invoke_async(
      "hello",
      on_event: ->(event) { events << event.type }
    ).wait_result

    expect(result[:output]).to eq("answer")
    expect(events).to eq([:done])
  end

  it "accepts an event listener block for invoke_async" do
    events = []
    task = SymmetricAsyncEventAgent.new.invoke_async("hello") do |event|
      events << event.type
    end
    result = task.wait_result

    expect(result[:output]).to eq("answer")
    expect(events).to eq([:done])
  end

  it "accepts an event listener block for invoke" do
    events = []
    result = SymmetricAsyncEventAgent.new.invoke("hello") do |event|
      events << event.type
    end

    expect(result[:output]).to eq("answer")
    expect(events).to eq([:done])
  end

  it "keeps invoke_async listener optional" do
    result = SymmetricAsyncEventAgent.new.invoke_async("hello").wait_result

    expect(result[:output]).to eq("answer")
  end

  it "adds token events only for stream_async" do
    invoke_events = []
    stream_events = []
    agent = SymmetricAsyncEventAgent.new

    agent.invoke_async(
      "hello",
      on_event: ->(event) { invoke_events << event.type }
    ).wait_result

    agent.stream_async(
      "hello",
      on_event: ->(event) { stream_events << event.type }
    ).wait_result

    expect(invoke_events).to eq([:done])
    expect(stream_events).to include(:token)
    expect(stream_events.last).to eq(:done)
  end

  it "runs invoke_async and stream_async listeners on the EventLoop thread" do
    caller_thread = Thread.current
    event_loop = Phronomy::Runtime.instance.event_loop

    [:invoke_async, :stream_async].each do |method_name|
      callback_threads = []
      on_event_loop = []
      SymmetricAsyncEventAgent.new.public_send(
        method_name,
        "hello",
        on_event: ->(_event) {
          callback_threads << Thread.current
          on_event_loop << event_loop.current?
        }
      ).wait_result

      expect(callback_threads).not_to be_empty
      expect(callback_threads).to all(satisfy { |thread|
        thread != caller_thread
      })
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

  it "delivers :error before failing the Task for both async APIs" do
    bad_chat = build_chat(fake_response)
    allow(bad_chat).to receive(:ask).and_raise(RuntimeError, "LLM exploded")
    allow(bad_chat).to receive(:complete).and_raise(RuntimeError, "LLM exploded")
    allow(RubyLLM).to receive(:chat).and_return(bad_chat)

    [:invoke_async, :stream_async].each do |method_name|
      events = []
      task = SymmetricAsyncEventAgent.new.public_send(
        method_name,
        "hello",
        on_event: ->(event) { events << event.type }
      )

      expect { task.wait_result }.to raise_error(RuntimeError, "LLM exploded")
      expect(events.last).to eq(:error)
    end
  end

  it "distinguishes timeout from explicit cancellation" do
    timeout_events = []
    timeout_task = SymmetricAsyncEventAgent.new.invoke_async(
      "hello",
      config: {
        cancellation_token:
          Phronomy::Concurrency::CancellationToken.timeout_after(-1)
      },
      on_event: ->(event) { timeout_events << event.type }
    )

    expect { timeout_task.wait_result }
      .to raise_error(Phronomy::TimeoutError)
    expect(timeout_events).to eq([:timeout])

    token = Phronomy::Concurrency::CancellationToken.new
    token.cancel!
    cancellation_events = []
    cancellation_task = SymmetricAsyncEventAgent.new.invoke_async(
      "hello",
      config: {cancellation_token: token},
      on_event: ->(event) { cancellation_events << event.type }
    )

    expect { cancellation_task.wait_result }
      .to raise_error(Phronomy::CancellationError)
    expect(cancellation_events).to eq([:cancelled])
  end

  it "delivers the terminal event before settling the returned Task" do
    order = []
    task = SymmetricAsyncEventAgent.new.invoke_async(
      "hello",
      on_event: ->(event) {
        order << event.type if event.type == :done
      }
    )
    task.on_complete { |_value, _error| order << :task_completed }

    task.wait_result
    expect(order).to eq([:done, :task_completed])
  end

  it "keeps Task#on_complete active when on_event is also used" do
    callback_result = Queue.new
    task = SymmetricAsyncEventAgent.new.invoke_async(
      "hello",
      on_event: ->(_event) {}
    )
    task.on_complete do |value, error|
      callback_result << [value, error]
    end

    value, error = callback_result.pop
    expect(error).to be_nil
    expect(value[:output]).to eq("answer")
    expect(task.wait_result[:output]).to eq("answer")
  end

  it "invoke_async passes tracing InvocationContext without generic identity" do
    ic = Phronomy::InvocationContext.new(task_id: "ctx-task")
    captured_config = nil
    allow(Phronomy::Agent::AgentInvocationSessionBuilder)
      .to receive(:build)
      .and_wrap_original do |original, **kwargs|
        captured_config = kwargs[:config]
        original.call(**kwargs)
      end
    events = []
    result = SymmetricAsyncEventAgent.new.invoke_async(
      "hello",
      invocation_context: ic,
      on_event: ->(event) { events << event.type }
    ).wait_result
    expect(result[:output]).to eq("answer")
    expect(events).to eq([:done])
    expect(captured_config).to include(invocation_context: ic)
    expect(captured_config).not_to have_key(:thread_id)
    expect(captured_config).not_to have_key(:session_id)
  end

  it "stream_async passes tracing InvocationContext through" do
    ic = Phronomy::InvocationContext.new(task_id: "ctx-stream")
    events = []
    SymmetricAsyncEventAgent.new.stream_async(
      "hello",
      invocation_context: ic,
      on_event: ->(event) { events << event.type }
    ).wait_result
    expect(events).to include(:done)
  end

  it "stream passes tracing InvocationContext through" do
    ic = Phronomy::InvocationContext.new(task_id: "ctx-stream-sync")
    events = []
    SymmetricAsyncEventAgent.new.stream(
      "hello",
      invocation_context: ic,
      on_event: ->(event) { events << event.type }
    )
    expect(events).to include(:done)
  end

  it "invoke APIs raise ArgumentError when on_event: and block are both given" do
    [:invoke, :invoke_async].each do |method_name|
      expect {
        SymmetricAsyncEventAgent.new.public_send(
          method_name,
          "hello",
          on_event: ->(_event) {}
        ) do |_event|
        end
      }.to raise_error(ArgumentError, /on_event.*block|block.*on_event/i)
    end
  end

  it "stream_async raises ArgumentError when on_event: and block are both given" do
    expect {
      SymmetricAsyncEventAgent.new.stream_async(
        "hello",
        on_event: ->(_event) {},
        &->(_event) {}
      )
    }.to raise_error(ArgumentError, /on_event.*block|block.*on_event/i)
  end
end

# Unit tests for check_cancellation! error classification (avoids async EventLoop timing).
RSpec.describe "Agent::Base#check_cancellation!" do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) { agent_definition id: "test-agent-201", version: 1 }
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
