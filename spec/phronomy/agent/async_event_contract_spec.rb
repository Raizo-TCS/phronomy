# frozen_string_literal: true

require "spec_helper"

class SymmetricAsyncEventAgent < Phronomy::Agent::Base
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
      cache_creation: 0
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
        messages: [],
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
        messages: [],
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

  it "invoke_async passes invocation_context: through to config" do
    ic = Phronomy::InvocationContext.new(thread_id: "ctx-thread")
    agent = SymmetricAsyncEventAgent.new
    expect(agent).to receive(:_apply_invocation_context).with(
      anything, anything, ic
    ).and_call_original
    events = []
    result = agent.invoke_async(
      "hello",
      invocation_context: ic,
      on_event: ->(event) { events << event.type }
    ).wait_result
    expect(result[:output]).to eq("answer")
    expect(events).to eq([:done])
  end

  it "stream_async passes invocation_context: through to config" do
    ic = Phronomy::InvocationContext.new(thread_id: "ctx-stream")
    events = []
    SymmetricAsyncEventAgent.new.stream_async(
      "hello",
      invocation_context: ic,
      on_event: ->(event) { events << event.type }
    ).wait_result
    expect(events).to include(:done)
  end

  it "stream passes invocation_context: through to config" do
    ic = Phronomy::InvocationContext.new(thread_id: "ctx-stream-sync")
    events = []
    SymmetricAsyncEventAgent.new.stream(
      "hello",
      invocation_context: ic,
      on_event: ->(event) { events << event.type }
    )
    expect(events).to include(:done)
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

# Direct unit tests for normalize_terminal_error and invocation_timeout_expired?
# to avoid relying on async EventLoop timing for branch coverage.
RSpec.describe "Agent::AsyncEventApi normalize_terminal_error" do
  let(:agent) { Class.new(Phronomy::Agent::Base).new }

  def normalize(error, config = {})
    invocation = double("invocation", config: config)
    agent.send(:normalize_terminal_error, error, invocation)
  end

  it "returns non-CancellationError unchanged" do
    err = RuntimeError.new("boom")
    expect(normalize(err)).to be(err)
  end

  it "returns CancellationError unchanged when no deadline is set" do
    token = Phronomy::Concurrency::CancellationToken.new
    token.cancel!
    err = Phronomy::CancellationError.new("explicit cancel")
    result = normalize(err, {cancellation_token: token})
    expect(result).to be_a(Phronomy::CancellationError)
  end

  it "converts CancellationError to TimeoutError when wall-clock deadline has expired" do
    token = Phronomy::Concurrency::CancellationToken.new(deadline: Time.now - 1)
    err = Phronomy::CancellationError.new("deadline")
    result = normalize(err, {cancellation_token: token})
    expect(result).to be_a(Phronomy::TimeoutError)
    expect(result.message).to eq("deadline")
  end

  it "returns CancellationError unchanged when invocation is nil" do
    err = Phronomy::CancellationError.new("nil invocation")
    result = agent.send(:normalize_terminal_error, err, nil)
    expect(result).to be_a(Phronomy::CancellationError)
  end

  it "converts to TimeoutError when InvocationContext has an expired deadline" do
    ic = Phronomy::InvocationContext.new(
      deadline: Phronomy::Concurrency::Deadline.in(-1)
    )
    err = Phronomy::CancellationError.new("ic deadline")
    invocation = double("invocation", config: {invocation_context: ic})
    result = agent.send(:normalize_terminal_error, err, invocation)
    expect(result).to be_a(Phronomy::TimeoutError)
  end

  it "converts to TimeoutError for monotonic deadline token (timeout_after)" do
    token = Phronomy::Concurrency::CancellationToken.timeout_after(-1)
    err = Phronomy::CancellationError.new("monotonic")
    result = normalize(err, {cancellation_token: token})
    expect(result).to be_a(Phronomy::TimeoutError)
  end
end
