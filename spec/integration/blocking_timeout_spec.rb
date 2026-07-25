# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/llm_stub"

module BlockingTimeoutFixtures
  class SlowBlockingTool < Phronomy::Agent::Context::Capability::Base
    tool_name "slow_blocking_tool"
    description "Sleeps before returning the supplied input"
    execution_mode :blocking_io
    param :input, type: :string, desc: "Value to return"

    def execute(input:)
      sleep 0.2
      input
    end
  end
end

RSpec.describe "BlockingAdapterPool Agent timeout propagation", :integration do
  around(:each) do |example|
    old_runtime = Phronomy::Runtime.instance
    runtime = Phronomy::Runtime.new
    Phronomy::Runtime.instance = runtime
    example.run
  ensure
    LLMStub.deactivate
    runtime&.shutdown
    Phronomy::Runtime.instance = old_runtime
  end

  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      model "openai/gpt-oss-20b"
      provider :openai
      instructions "You are a timeout test assistant."
    end
  end

  it "raises TimeoutError when llm_timeout fires before the adapter returns" do
    recorder = LLMStub::Recorder.new(["late response"])
    WebMock.disable_net_connect!
    WebMock.stub_request(:post, LLMStub::CHAT_ENDPOINT_PATTERN)
      .to_return do |request|
        sleep 0.2
        recorder.handle(request)
      end

    expect {
      agent_class.new.invoke("hello", config: {llm_timeout: 0.05})
    }.to raise_error(Phronomy::TimeoutError)
  end

  it "raises TimeoutError when tool_timeout fires before a blocking_io tool returns" do
    tool_response = LLMStub.tool_call_response(
      "slow_blocking_tool",
      {input: "hello"}
    )
    LLMStub.activate(responses: [tool_response, "done"])

    klass = Class.new(agent_class) do
      tools BlockingTimeoutFixtures::SlowBlockingTool
      instructions "Always call slow_blocking_tool with input 'hello'."
    end

    expect {
      klass.new.invoke("run the tool", config: {tool_timeout: 0.05})
    }.to raise_error(Phronomy::TimeoutError)
  end
end
