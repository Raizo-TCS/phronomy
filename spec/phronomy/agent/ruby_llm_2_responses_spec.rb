# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "timeout"

RSpec.describe "RubyLLM 2 Responses execution contract" do
  around do |example|
    config = RubyLLM.config
    saved = [config.openai_api_key, config.openai_api_base, config.openai_protocol]
    RubyLLM.configure do |value|
      value.openai_api_key = "test"
      value.openai_api_base = "https://responses.example.test/v1"
      value.openai_protocol = nil # RubyLLM chooses its official default.
    end
    example.run
  ensure
    config.openai_api_key, config.openai_api_base, config.openai_protocol = saved
  end

  def response(output)
    {id: "resp_test", object: "response", model: "gpt-4o-mini", status: "completed",
     output: output, usage: {input_tokens: 30, output_tokens: 7,
                             input_tokens_details: {cached_tokens: 5}}}
  end

  def text_output
    [{type: "message", id: "msg_test", role: "assistant", status: "completed",
      content: [{type: "output_text", text: "Done", annotations: []}]}]
  end

  def build_agent(approval: false, &events)
    tool = Class.new(Phronomy::Tool::Base) do
      tool_name "lookup"
      param :query, type: :string, required: true
      requires_approval approval
      def execute(query:) = "found:#{query}"
    end
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "responses-#{SecureRandom.hex(6)}", version: 1
      model "gpt-4o-mini"
      provider :openai
      max_output_tokens 321
      tools tool => nil
    end.new(on_event: events)
  end

  [false, true].each do |approval|
    it "continues a Tool exchange through Responses with approval=#{approval}" do
      requests = []
      stub_request(:post, "https://responses.example.test/v1/responses").to_return do |request|
        requests << JSON.parse(request.body)
        output = if requests.length == 1
          [{type: "function_call", id: "fc_test", call_id: "call_test", name: "lookup",
            arguments: '{"query":"record"}', status: "completed"}]
        else
          text_output
        end
        {headers: {"Content-Type" => "application/json"}, body: JSON.generate(response(output))}
      end
      approvals = Queue.new
      agent = build_agent(approval: approval) do |event|
        approvals << event.payload.fetch(:request) if event.type == :approval_required
      end
      chats = []
      allow(RubyLLM).to receive(:chat).and_wrap_original do |original, **options|
        original.call(**options).tap { |chat| chats << chat }
      end
      task = agent.invoke_async("look up record")
      if approval
        request = Timeout.timeout(5) { approvals.pop }
        expect(requests.size).to eq(1)
        agent.approve_async(request.execution_id, approval_request_id: request.id).wait_result(timeout: 5)
      end
      result = task.wait_result(timeout: 5)
      expect(result[:output]).to eq("Done")
      expect(requests.length).to eq(2)
      expect(chats).to all(have_attributes(max_output_tokens: 321))
      expect(requests.last.fetch("input")).to include(
        include("type" => "function_call_output", "call_id" => "call_test", "output" => "found:record")
      )
    end
  end

  it "streams text and records the RubyLLM 2 token counters" do
    response_data = response(text_output)
    events = [
      {type: "response.output_text.delta", output_index: 0, content_index: 0, delta: "Done"},
      {type: "response.completed", response: response_data}
    ]
    stub_request(:post, "https://responses.example.test/v1/responses")
      .to_return(headers: {"Content-Type" => "text/event-stream"},
        body: events.map { |event| "data: #{JSON.generate(event)}\n\n" }.join)
    tokens = []
    agent = build_agent { |event| tokens << event.payload[:content] if event.type == :token }
    result = agent.stream_async("hello").wait_result(timeout: 5)
    expect(result[:output]).to eq("Done")
    expect(tokens.join).to eq("Done")
    expect(result[:usage]).to have_attributes(input: 25, output: 7, cached: 5)
  end
end
