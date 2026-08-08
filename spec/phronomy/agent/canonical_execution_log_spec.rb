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
end
