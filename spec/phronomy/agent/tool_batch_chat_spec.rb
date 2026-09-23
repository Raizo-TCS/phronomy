# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "timeout"

RSpec.describe "Agent Tool batches through ordinary RubyLLM chat" do
  before do
    @llm_config = RubyLLM.config
    @old_api_base = @llm_config.openai_api_base
    @old_api_key = @llm_config.openai_api_key
    RubyLLM.configure do |config|
      config.openai_api_base = "https://tool-batch.example.invalid/v1"
      config.openai_api_key = "test-api-key"
    end
    @started = Queue.new
    @finished = Queue.new
    @approvals = Queue.new
    @gates = {"a" => Queue.new, "b" => Queue.new}
    @requests = []
    @chats = []
    @events = []
    allow(RubyLLM).to receive(:chat).and_wrap_original do |method, **options|
      method.call(**options).tap { |chat| @chats << chat }
    end
  end

  after do
    @gates.each_value { |gate| gate << true }
    Phronomy.reset_runtime!
    RubyLLM.configure do |config|
      config.openai_api_base = @old_api_base
      config.openai_api_key = @old_api_key
    end
  end

  def pop(queue)
    Timeout.timeout(5) { queue.pop }
  end

  def build_agent(approval: false, fail_on: nil)
    started, finished, gates = @started, @finished, @gates
    tool = Class.new(Phronomy::Tool::Base) do
      tool_name "batch_lookup"
      description "Look up independent values"
      execution_mode :offloaded
      requires_approval approval
      on_error :raise
      param :value, type: :string, desc: "Lookup value"
      define_method(:execute) do |value:|
        started << value
        gates.fetch(value).pop
        raise Phronomy::ToolError, "lookup failed" if value == fail_on

        finished << value
        "result:#{value}"
      end
    end
    klass = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "tool-batch-#{SecureRandom.hex(6)}", version: 1
      model "test-model"
      provider :openai

      max_output_tokens 512
      instructions "Use the requested lookups and report their results."
      tools tool => nil
    end
    klass.new(on_event: lambda { |event|
      @events << event
      @approvals << event.payload.fetch(:request) if event.type == :approval_required
    })
  end

  def tool_calls(values)
    values.map do |value|
      {id: "call_#{value}", type: "function", function: {
        name: "batch_lookup", arguments: {value: value}.to_json
      }}
    end
  end

  def stub_conversation(values)
    stub_request(:post, "https://tool-batch.example.invalid/v1/chat/completions")
      .to_return do |request|
        payload = JSON.parse(request.body)
        @requests << payload
        calls = (@requests.size == 1 && !values.empty?) ? tool_calls(values) : nil
        if payload["stream"]
          {status: 200, headers: {"Content-Type" => "text/event-stream"}, body: stream_response(calls)}
        else
          message = {role: "assistant", content: calls ? nil : "Done"}
          message[:tool_calls] = calls if calls
          response = {
            id: "chatcmpl-batch", object: "chat.completion", created: 0, model: "test-model",
            choices: [{index: 0, message: message, finish_reason: calls ? "tool_calls" : "stop"}],
            usage: {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
          }
          {status: 200, headers: {"Content-Type" => "application/json"}, body: response.to_json}
        end
      end
  end

  def stream_response(calls)
    deltas = [{role: "assistant", content: ""}]
    if calls
      calls.each_with_index { |call, index| deltas << {tool_calls: [call.merge(index: index)]} }
    else
      deltas << {content: "Done"}
    end
    chunks = deltas.map do |delta|
      {id: "chatcmpl-batch", object: "chat.completion.chunk", created: 0, model: "test-model",
       choices: [{index: 0, delta: delta, finish_reason: nil}]}
    end
    chunks << {id: "chatcmpl-batch", object: "chat.completion.chunk", created: 0, model: "test-model",
               choices: [{index: 0, delta: {}, finish_reason: calls ? "tool_calls" : "stop"}]}
    chunks.map { |chunk| "data: #{chunk.to_json}\n\n" }.join + "data: [DONE]\n\n"
  end

  def expect_tool_exchange(values)
    expect(@chats).not_to be_empty
    expect(@chats).to all(be_an_instance_of(RubyLLM::Chat))
    expect(@requests.size).to eq(2)
    messages = @requests.last.fetch("messages")
    requests = messages.select { |message| message["tool_calls"] }
    results = messages.select { |message| message["role"] == "tool" }
    expect(requests.size).to eq(1)
    expect(requests.first.fetch("tool_calls").map { |call| call.fetch("id") })
      .to eq(values.map { |value| "call_#{value}" })
    expect(results.map { |message| message.fetch("tool_call_id") })
      .to eq(values.map { |value| "call_#{value}" })
    expect(results.map { |message| message.fetch("content") })
      .to eq(values.map { |value| "result:#{value}" })
    expect(@events.count { |event| event.type == :tool_call }).to eq(values.size)
    expect(@events.count { |event| event.type == :tool_result }).to eq(values.size)
  end

  it "completes a response without Tool calls through ordinary chat" do
    stub_conversation([])
    result = build_agent.invoke_async("hello").wait_result(timeout: 5)
    expect(result[:output]).to eq("Done")
    expect(@requests.size).to eq(1)
    expect(@chats).to all(be_an_instance_of(RubyLLM::Chat))
    expect(@started).to be_empty
  end

  it "executes a single Tool call exactly once and returns its result" do
    stub_conversation(["a"])
    @gates.fetch("a") << true
    result = build_agent.invoke_async("look up a").wait_result(timeout: 5)
    expect(result[:output]).to eq("Done")
    expect(pop(@started)).to eq("a")
    expect(@started).to be_empty
    expect_tool_exchange(["a"])
  end

  %i[invoke_async stream_async].each do |entry_point|
    it "overlaps both Tools and joins ordered results before the next #{entry_point} Provider call" do
      stub_conversation(%w[a b])
      task = build_agent.public_send(entry_point, "look up a and b")
      expect([pop(@started), pop(@started)]).to contain_exactly("a", "b")

      # Finish the second call first. The first call is still blocked, so no
      # partial Tool-result batch may be sent back to the Provider.
      @gates.fetch("b") << true
      expect(pop(@finished)).to eq("b")
      expect(@requests.size).to eq(1)
      expect(task).not_to be_done

      @gates.fetch("a") << true
      expect(task.wait_result(timeout: 5)[:output]).to eq("Done")
      expect(@started).to be_empty
      expect_tool_exchange(%w[a b])
      if entry_point == :stream_async
        expect(@requests).to all(include("stream" => true))
        expect(@events.select { |event| event.type == :token }.map { |event| event.payload[:content] }.join)
          .to eq("Done")
      end
    end
  end

  it "suspends the entire batch before execution and resumes both Tools after approval" do
    stub_conversation(%w[a b])
    agent = build_agent(approval: true)
    task = agent.invoke_async("look up a and b")
    request = pop(@approvals)
    expect(request.items.map(&:tool_call_id)).to eq(%w[call_a call_b])
    expect(@started).to be_empty
    expect(task).not_to be_done
    expect(@requests.size).to eq(1)

    approval = agent.approve_async(request.execution_id, approval_request_id: request.id)
    expect([pop(@started), pop(@started)]).to contain_exactly("a", "b")
    @gates.each_value { |gate| gate << true }
    expect(task.wait_result(timeout: 5)[:output]).to eq("Done")
    expect(approval.wait_result(timeout: 5)[:output]).to eq("Done")
    expect_tool_exchange(%w[a b])
  end

  it "reports an F0 Tool failure without making a Provider continuation from partial results" do
    stub_conversation(%w[a b])
    task = build_agent(fail_on: "a").invoke_async("look up a and b")
    expect([pop(@started), pop(@started)]).to contain_exactly("a", "b")
    @gates.each_value { |gate| gate << true }
    expect { task.wait_result(timeout: 5) }.to raise_error(Phronomy::ToolError, /lookup failed/)
    expect(@requests.size).to eq(1)
  end
end
