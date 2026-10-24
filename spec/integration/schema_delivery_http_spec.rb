# frozen_string_literal: true

require "spec_helper"
require "webrick"
require "json"

RSpec.describe "Agent schema delivery HTTP payloads", :integration do
  let(:schema) { {type: "object", properties: {answer: {type: "string"}}, required: ["answer"], additionalProperties: false} }
  let(:requests) { [] }
  let(:tool_count) { [0] }
  let(:agent_class) do
    count = tool_count
    tool = Class.new(Phronomy::Tool::Base) do
      tool_name "fixed_read"
      description "A controlled fixed read"
      define_method(:execute) {
        count[0] += 1
        "fixed value"
      }
    end
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "http-schema-delivery", version: 1
      model "gpt-4o-mini"
      provider :openai
      tools tool => nil
    end
  end

  around do |example|
    saved = %i[openai_api_base openai_api_key openai_protocol max_retries].to_h { |key| [key, RubyLLM.config.public_send(key)] }
    WebMock.disable! if defined?(WebMock)
    captured = requests
    server = WEBrick::HTTPServer.new(Port: 0, BindAddress: "127.0.0.1", Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    server.mount_proc("/v1/chat/completions") do |request, response|
      body = JSON.parse(request.body)
      captured << body
      # Every execution makes exactly one Tool turn followed by one final turn.
      tool_turn = body.fetch("messages").none? { |message| message["role"] == "tool" }
      message = if tool_turn
        {role: "assistant", content: nil, tool_calls: [{id: "read-1", type: "function", function: {name: "fixed_read", arguments: "{}"}}]}
      else
        {role: "assistant", content: '{"answer":"ok"}'}
      end
      finish = tool_turn ? "tool_calls" : "stop"
      if body["stream"]
        delta = message.dup
        delta[:tool_calls] = message[:tool_calls].map { |call| call.merge(index: 0) } if tool_turn
        chunks = [[delta, nil], [{}, finish]].map do |value, reason|
          {id: "test", object: "chat.completion.chunk", created: 0, model: "gpt-4o-mini", choices: [{index: 0, delta: value, finish_reason: reason}]}
        end
        response["Content-Type"] = "text/event-stream"
        response.body = chunks.map { |chunk| "data: #{JSON.generate(chunk)}\n\n" }.join + "data: [DONE]\n\n"
      else
        response["Content-Type"] = "application/json"
        response.body = JSON.generate(id: "test", object: "chat.completion", created: 0, model: "gpt-4o-mini",
          choices: [{index: 0, message: message, finish_reason: finish}], usage: {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15})
      end
    end
    thread = Thread.new { server.start }
    RubyLLM.configure do |c|
      c.openai_api_base = "http://127.0.0.1:#{server.config.fetch(:Port)}/v1"
      c.openai_api_key = "test-only"
      c.openai_protocol = :chat_completions
      c.max_retries = 0
    end
    example.run
  ensure
    server&.shutdown
    thread&.join
    saved&.each { |key, value| RubyLLM.config.public_send("#{key}=", value) }
    WebMock.enable! if defined?(WebMock)
  end

  %i[invoke stream].each do |entry|
    [nil, :native, :none].each do |delivery|
      it "keeps Tools on both #{entry} turns with #{delivery || :default} delivery" do
        agent = agent_class.create(on_event: ->(_event) {})
        options = {output_schema: schema}
        options[:schema_delivery] = delivery unless delivery.nil?
        expect(agent.public_send(entry, "Return JSON", **options)[:output]).to eq("answer" => "ok")
        expect(tool_count).to eq([1])
        expect(requests.length).to eq(2)
        requests.each do |body|
          expect(body.fetch("tools").map { |item| item.dig("function", "name") }).to eq(["fixed_read"])
          if delivery == :none
            expect(body).not_to have_key("response_format")
            expect(body).not_to have_key("schema_delivery")
          else
            expect(body.dig("response_format", "type")).to eq("json_schema")
            expect(body.dig("response_format", "json_schema", "schema")).to eq(JSON.parse(schema.to_json))
          end
          expect(body.fetch("messages").last["role"]).to eq(body.equal?(requests.first) ? "user" : "tool")
        end
      end
    end
  end
end
