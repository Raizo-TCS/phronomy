# frozen_string_literal: true

require "spec_helper"
require_relative "../multi_agent/support/durable_coordination"

RSpec.describe "Output filtering across ordinary execution and Recovery" do
  include_context "durable coordination runtime"

  [:ordinary, :resolve, :restart].product([:transform, :block, :raise], [:invoke, :stream]).each do |route, behavior, mode|
    it "settles #{behavior} output filtering through #{route} in #{mode} mode" do
      filtered = 0
      filter = Class.new(Phronomy::Filter::Base) do
        define_method(:call) do |value, **_context|
          next value unless value == "target output"
          filtered += 1
          case behavior
          when :transform then "filtered output"
          when :block then block!("output filter rejected")
          when :raise then raise "output filter failed"
          end
        end
      end
      worker.output_filter(filter)
      agent = worker.create(agent_id: "output-recovery", persistence: store, on_event: ->(_event) {})
      expected = {transform: :completed, block: :blocked, raise: :failed}.fetch(behavior)
      if route == :ordinary
        activate_filter_response(mode, "target output")
        invoke_filtered_output(behavior) { agent.public_send(mode, "input") }
        backend = store
        id = store.list_executions(agent.agent_id).first.execution_id
      else
        before_provider = nil
        store.after_commit = proc do |current|
          run = current.list_executions(agent.agent_id).first
          before_provider ||= current.snapshot if run&.phase == :calling_llm
        end
        activate_filter_response(mode, "original output")
        agent.public_send(mode, "input")
        expect(before_provider).not_to be_nil
        backend = reboot(before_provider)
        events = Queue.new
        agent = worker.load(agent.agent_id, persistence: backend,
          on_event: ->(event) { events << event.payload if event.type == :recovery_resolution_required })
        event = Timeout.timeout(3) { events.pop }
        id = event.fetch(:execution_id)
        after_resolution = nil
        backend.after_commit = proc do |current|
          run = current.executions.load(id)
          after_resolution ||= current.snapshot if run.phase == :recovery_provider_completed
        end
        llm = LLMStub.activate(responses: ["must not replay"])
        outcome = Phronomy::Agent::ProviderCallOutcome.new(role: :assistant, content: "target output", tool_calls: [])
        invoke_filtered_output(behavior) do
          agent.resolve_async(id, expected_execution_revision: event.fetch(:execution_revision),
            subject: event.fetch(:subject), outcome: :succeeded, result: outcome.to_h).wait_result(timeout: 3)
        end
        expect(llm.calls).to be_empty
        if route == :restart
          expect(after_resolution).not_to be_nil
          backend = reboot(after_resolution)
          terminal = Queue.new
          backend.after_commit = proc do |current|
            run = current.executions.load(id)
            terminal << run if run.terminal?
          end
          filtered = 0
          llm = LLMStub.activate(responses: ["must not replay"])
          agent = worker.load(agent.agent_id, persistence: backend)
          expect(Timeout.timeout(3) { terminal.pop }.status).to eq(expected)
          expect(llm.calls).to be_empty
        end
      end

      run = backend.executions.load(id)
      expect(run.status).to eq(expected)
      expect(filtered).to eq(1)
      if behavior == :transform
        expect(backend.execution_result(id)[:result]).to eq("filtered output")
      else
        expect(backend.execution_result(id)[:error].fetch("message")).to match(/output filter (rejected|failed)/)
      end
      # A handled filter failure must release admission for the same Agent.
      LLMStub.activate(responses: ["next output"])
      expect(agent.invoke("next input")[:output]).to eq("next output")
    end
  end

  # The shared LLMStub emits JSON only. Exercise real stream parsing here with
  # a text-only SSE response while retaining its Provider request recorder.
  def activate_filter_response(mode, content)
    recorder = LLMStub.activate(responses: [content])
    return recorder unless mode == :stream

    chunks = [
      {delta: {role: "assistant", content: content}, finish_reason: nil},
      {delta: {}, finish_reason: "stop"}
    ].map do |choice|
      "data: #{JSON.generate(id: "chatcmpl-filter", object: "chat.completion.chunk",
        created: 0, model: "gpt-4o-mini", choices: [choice.merge(index: 0)])}\n\n"
    end
    body = chunks.join + "data: [DONE]\n\n"
    WebMock.stub_request(:post, LLMStub::CHAT_ENDPOINT_PATTERN)
      .with { |request| JSON.parse(request.body)["stream"] }
      .to_return do |request|
        recorder.handle(request)
        {status: 200, headers: {"Content-Type" => "text/event-stream"}, body: body}
      end
    recorder
  end

  def invoke_filtered_output(behavior)
    if behavior == :transform
      expect(yield[:output]).to eq("filtered output")
    else
      expect { yield }.to raise_error(StandardError, /output filter (rejected|failed)/)
    end
  end
end
