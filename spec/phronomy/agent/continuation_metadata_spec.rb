# frozen_string_literal: true

require "spec_helper"
require_relative "../multi_agent/support/durable_coordination"

RSpec.describe "Agent preservation of backend-owned conversation metadata" do
  include_context "durable coordination runtime"
  let(:opaque) { {"independent_backend" => {"version" => 1, "data" => ["opaque", {"signed" => "value"}]}} }

  def independent_adapter(&operation)
    Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:initialize) { |callback| @callback = callback }
      protected

      define_method(:perform_complete) { |request, cancellation_token:| @callback.call(request) }
    end.new(operation)
  end

  def sdk_reply(tool: true)
    message = {role: "assistant", content: tool ? "" : "done", reasoning: "synthetic continuation", reasoning_signature: "opaque-signature"}
    message[:tool_calls] = [{id: "lookup-1", type: "function", function: {name: "protected_lookup", arguments: "{}"}}] if tool
    {model: "gpt-4o-mini", choices: [{index: 0, message: message, finish_reason: tool ? "tool_calls" : "stop"}]}
  end

  %i[invoke_async stream_async].each do |mode|
    it "preserves reasoning through the complete Agent Tool loop with #{mode}" do
      count = 0
      tool = Class.new(Phronomy::Tool::Base) do
        tool_name "protected_lookup"
        description "Lookup"
        define_method(:execute) {
          count += 1
          "found"
        }
      end
      worker.tools tool => nil
      calls = []
      stub_request(:post, "https://example.test/v1/chat/completions").to_return do |r|
        calls << JSON.parse(r.body)
        response = sdk_reply(tool: calls.length == 1)
        if calls.last["stream"]
          choice = response[:choices].first
          delta = choice[:message].dup
          delta[:tool_calls]&.each_with_index { |c, i| c[:index] = i }
          body = [{model: response[:model], choices: [{index: 0, delta: delta, finish_reason: nil}]},
            {model: response[:model], choices: [{index: 0, delta: {}, finish_reason: choice[:finish_reason]}]}]
          {headers: {"Content-Type" => "text/event-stream"}, body: body.map { |c| "data: #{JSON.generate(c)}\n\n" }.join + "data: [DONE]\n\n"}
        else
          {headers: {"Content-Type" => "application/json"}, body: JSON.generate(response)}
        end
      end
      events = []
      agent = worker.create(persistence: store.agent, on_event: ->(e) { events << e })
      expect(agent.public_send(mode, "lookup").wait_result(timeout: 5)[:output]).to eq("done")
      expect(count).to eq(1)
      expect(calls.length).to eq(2)
      expect(events.select { |e| e.type == :token }.map { |e| e.payload[:content] }.compact.join).not_to include("synthetic continuation")
      expect(calls.last["messages"]).to include(include("role" => "assistant", "reasoning" => "synthetic continuation", "reasoning_signature" => "opaque-signature"))
      # A subsequent invocation must rebuild from the durable Journal, too.
      agent.invoke("continue")
      expect(count).to eq(1)
      assistants = calls.last["messages"].select { |m| m["role"] == "assistant" }
      expect(assistants.length).to eq(2)
      expect(assistants).to all(include("reasoning" => "synthetic continuation"))
    end
  end

  it "replays SDK reasoning after durable approval restoration without repeating the first request" do
    count = 0
    tool = Class.new(Phronomy::Tool::Base) do
      tool_name "protected_lookup"
      description "Lookup"
      requires_approval true
      define_method(:execute) {
        count += 1
        "found"
      }
    end
    worker.tools tool => nil
    first = LLMStub.activate(responses: [JSON.parse(JSON.generate(sdk_reply))])
    approvals = Queue.new
    listener = ->(e) { approvals << e.payload.fetch(:request) if e.type == :approval_required }
    agent = worker.create(agent_id: "sdk-approval", persistence: store.agent, on_event: listener)
    agent.invoke_async("lookup")
    approval = Timeout.timeout(3) { approvals.pop }
    recovered = reboot(store.snapshot)
    second = LLMStub.activate(responses: ["done"])
    loaded = worker.load(agent.agent_id, persistence: recovered.agent, on_event: listener)
    restored = Timeout.timeout(3) { approvals.pop }
    expect(loaded.approve(approval.execution_id, approval_request_id: restored.id, approved: true)[:output]).to eq("done")
    expect(count).to eq(1)
    expect(first.calls.length).to eq(1)
    expect(second.calls.length).to eq(1)
    expect(second.last_messages).to include(include("role" => "assistant", "reasoning" => "synthetic continuation", "reasoning_signature" => "opaque-signature"))
  end

  it "preserves opaque metadata across approval, a fresh Runtime and backend reconstruction" do
    count = 0
    tool = Class.new(Phronomy::Tool::Base) do
      tool_name "protected_lookup"
      description "One approved lookup"
      requires_approval true
      define_method(:execute) {
        count += 1
        "found"
      }
    end
    worker.tools tool => nil
    metadata = opaque
    Phronomy.configure { |c|
      c.llm_adapter = independent_adapter { |_|
        Phronomy::LLMAdapter::Response.new(metadata: metadata, tool_calls: [Phronomy::Tool::CallRequest.new(id: "lookup-1", name: "protected_lookup", arguments: {})])
      }
    }
    expect(RubyLLM).not_to receive(:chat)
    approvals = Queue.new
    listener = ->(e) { approvals << e.payload.fetch(:request) if e.type == :approval_required }
    original = worker.create(agent_id: "opaque-approval", persistence: store.agent, on_event: listener)
    original.invoke_async("lookup")
    approval = Timeout.timeout(3) { approvals.pop }
    expect(count).to eq(0)
    restored_store = reboot(store.snapshot)
    seen = []
    Phronomy.configure { |c|
      c.llm_adapter = independent_adapter { |request|
        seen << request
        Phronomy::LLMAdapter::Response.new(content: "done", metadata: metadata)
      }
    }
    restored = worker.load(original.agent_id, persistence: restored_store.agent, on_event: listener)
    again = Timeout.timeout(3) { approvals.pop }
    expect(restored.approve(approval.execution_id, approval_request_id: again.id, approved: true)[:output]).to eq("done")
    expect(count).to eq(1)
    expect(seen.length).to eq(1)
    assistant = seen.first.messages.find { |m| m.role == :assistant }
    expect(assistant.metadata).to eq(opaque)
    expect(assistant.metadata.fetch("independent_backend").fetch("data")).to be_frozen
    expect(seen.first.messages.last).to have_attributes(role: :tool, tool_call_id: "lookup-1", content: "found")
  end

  [false, true].each do |different_model|
    it "preserves selected Handoff history and checks its backend scope with model change=#{different_model}" do
      tool = Class.new(Phronomy::Tool::Base) do
        tool_name "protected_lookup"
        description "Lookup"
        def execute = "found"
      end
      worker.tools tool => nil
      source = worker.create(persistence: store.agent)
      target_model = different_model ? "different-local-model" : "gpt-4o-mini"
      target_class = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "continuation-handoff-target", version: 1
        model target_model
        provider :openai
      end
      target = target_class.create(persistence: store.agent)
      policy = Phronomy::MultiAgent::HandoffPolicy.define do
        required :current_request
        forbidden :history
        selectable :knowledge, default: :exclude
        selectable :tool_exchanges, default: :include
      end
      handoff = Phronomy::MultiAgent::Handoff.new(source_agent: source, target_agent: target, policy: policy)
      name = Phronomy::MultiAgent::HandoffCapabilityFactory.build(handoff).tool_name
      recorder = LLMStub.activate(responses: [JSON.parse(JSON.generate(sdk_reply)),
        LLMStub.tool_call_response(name, {responsibility: "Continue"}), "done"])
      runner = Phronomy::MultiAgent::HandoffRunner.new(persistence: store.multi_agent,
        main_agent: source, handoffs: [handoff])
      if different_model
        # HandoffRunner observes the persisted failure through its existing
        # ExecutionObservation error projection, which reconstructs Phronomy::Error.
        expect { runner.invoke("lookup then hand off") }.to raise_error(Phronomy::Error, /Phronomy::ConfigurationError:.*continuation/)
        expect(recorder.calls.length).to eq(2)
      else
        expect(runner.invoke("lookup then hand off")[:output]).to eq("done")
        expect(recorder.calls.length).to eq(3)
        expect(recorder.last_messages).to include(include("role" => "assistant", "reasoning" => "synthetic continuation"))
      end
    end
  end

  it "preserves explicit Message metadata through the public context import boundary" do
    original = Phronomy::LLMAdapter::Message.new(role: :assistant, content: "previous", metadata: opaque)
    imported = Phronomy::Agent::ContextImporter.import_messages([original])
    payload = imported.records.first.content
    persistence = store.agent
    record = Phronomy::Agent::JournalRecord.new(agent_id: "imported", kind: :assistant_message,
      channel: :llm, role: :assistant, content_ref: persistence.contents.put_json(payload))
    message = Phronomy::Agent::RuntimeInput.new(agent: Object.new, persistence: persistence).materialize_journal_record(record)
    expect(message.metadata).to eq(opaque)
    expect(imported.records.first.metadata).not_to have_key("independent_backend")
  end
end
