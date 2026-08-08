# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Canonical Complete Execution Log capture" do
  it "captures the complete assistant message before Tool execution is intercepted" do
    call_a = RubyLLM::ToolCall.new(id: "a", name: "one", arguments: {})
    call_b = RubyLLM::ToolCall.new(id: "b", name: "two", arguments: {})
    assistant = RubyLLM::Message.new(
      role: :assistant,
      content: "I will use two tools",
      tool_calls: {"a" => call_a, "b" => call_b}
    )

    fake_chat_class = Class.new do
      attr_reader :messages

      def initialize(message)
        @messages = [message]
      end

      def before_tool_call(&block)
        @before_tool_call = block
      end

      def trigger(tool_call)
        @before_tool_call.call(tool_call)
      end
    end
    chat = fake_chat_class.new(assistant)
    invocation = Struct.new(:current_llm_call_id).new("llm-1")

    Phronomy::Agent::AgentInvocationSessionBuilder.send(
      :install_tool_interceptors,
      chat,
      invocation
    )

    expect { chat.trigger(call_a) }
      .to raise_error(Phronomy::Agent::ToolCallIntercepted) do |error|
        expect(error.assistant_message).to equal(assistant)
        expect(error.assistant_outcome.content.to_s).to eq("I will use two tools")
        expect(error.assistant_outcome.tool_calls.map { |call| call.fetch("id") })
          .to contain_exactly("a", "b")
        expect(error.tool_calls.map(&:id)).to contain_exactly("a", "b")
        expect(error.llm_call_id).to eq("llm-1")
      end
  end

  it "continues canonical event recording after the Application listener fails" do
    execution = Struct.new(:execution_id).new("exec-1")
    projection = Struct.new(:manifest_ref, :manifest).new("manifest-1", Object.new)
    listener_calls = 0
    activation = Phronomy::Agent::AgentExecutionActivation.new(
      execution: execution,
      agent: Object.new,
      runtime_projection: projection,
      coordinator: Object.new,
      application_listener: ->(_event) {
        listener_calls += 1
        raise "callback failed"
      }
    )

    activation.record_event(Phronomy::Agent::StreamEvent.new(type: :tool_call, payload: {}))
    activation.record_event(Phronomy::Agent::StreamEvent.new(type: :tool_result, payload: {}))

    expect(listener_calls).to eq(1)
    expect(activation.runtime_snapshot.fetch(:runtime_events).map(&:type))
      .to eq(%i[tool_call tool_result])
  end

  it "records the exact Tool-role message separately from the raw Tool result" do
    events = []
    invocation = Phronomy::Agent::AgentInvocation.new(
      agent: Object.new,
      input: "input",
      config: {},
      event_listener: ->(event) { events << event }
    )
    chat = Class.new do
      attr_reader :messages

      def initialize
        @messages = []
      end

      def add_message(attributes)
        message = RubyLLM::Message.new(attributes)
        @messages << message
        message
      end
    end.new
    invocation.chat = chat
    invocation.tool_invocations = [
      Struct.new(:result, :tool_call_id, :tool_name).new(
        {price: 100}, "price-call", "price"
      )
    ]
    invocation.instance_variable_set(:@tool_batch_llm_call_id, "llm-1")

    invocation.record_tool_results!

    event = events.fetch(0)
    expect(event.type).to eq(:tool_result)
    expect(event.payload.fetch(:tool_result)).to eq(price: 100)
    expect(event.payload.fetch(:tool_message)).to eq(
      "role" => "tool",
      "content" => {price: 100}.inspect,
      "tool_call_id" => "price-call"
    )
    expect(chat.messages.fetch(0).content).to eq({price: 100}.inspect)
  end
end
