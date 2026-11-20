# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent exact execution result observations" do
  let(:schema) { {type: "object", properties: {answer: {type: "string"}}, required: ["answer"]} }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "exact-result-observation", version: 1
    end
  end
  let(:store) { Phronomy::PersistenceComposition.in_memory.agent }
  let(:agent) { agent_class.create(persistence: store) }
  let(:reservation) { Phronomy::Agent::ReservedExecution.new(agent_id: agent.agent_id, execution_id: "reserved-result") }
  let(:requests) { [] }
  let(:responses) { [Phronomy::LLMAdapter::Response.new(content: "invalid JSON", finish_reason: :stop)] }

  before do
    queue = responses
    captured = requests
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |request, cancellation_token:|
        captured << request
        queue.shift || raise("unexpected LLM replay")
      end
    end.new
    Phronomy.configure { |config| config.llm_adapter = adapter }
  end

  it "delivers a committed output failure as a result to current and late completion observers" do
    task = agent.start_reserved_async(reservation: reservation, input: "question", output_schema: schema)
    notifications = Queue.new
    task.on_complete { |value, error| notifications << [value, error] }
    result = task.wait_result(timeout: 5)
    expect(Timeout.timeout(5) { notifications.pop }).to eq([result, nil])
    expect(result).to include(agent_id: agent.agent_id, execution_id: reservation.execution_id,
      status: :failed, phase: :failed, output: nil, result: nil)
    expect(result[:error]).to include("class" => "Phronomy::Agent::OutputError",
      "reason" => "invalid_json", "raw_output" => "invalid JSON")
    expect(store.executions.load(reservation.execution_id).status).to eq(:failed)

    task.on_complete { |value, error| notifications << [value, error] }
    expect(Timeout.timeout(5) { notifications.pop }).to eq([result, nil])
    observed_again = agent.start_reserved_async(reservation: reservation, input: "question", output_schema: schema)
      .wait_result(timeout: 5)
    expect(observed_again).to eq(result)
    expect(requests.length).to eq(1)
  end

  [[RuntimeError, :failed], [Phronomy::CancellationError, :cancelled]].each do |error_class, status|
    it "returns the persisted #{status} result without converting it into an observation error" do
      agent_class.output_filter Class.new(Phronomy::Filter::Base) {
        define_method(:call) { |_value, **_context| raise error_class, "child execution ended" }
      }
      result = agent.start_reserved_async(reservation: reservation, input: "question").wait_result(timeout: 5)
      expect(result).to include(status: status, phase: status, output: nil, result: nil)
      expect(result[:error]).to include("class" => error_class.name, "message" => "child execution ended")
      expect(agent.resume(reservation.execution_id)).to eq(result)
      expect(requests.length).to eq(1)
    end
  end

  it "reports a result read failure as an operation error without changing the saved execution" do
    result = agent.invoke("question")
    execution_id = result.fetch(:execution_id)
    saved = store.executions.load(execution_id).to_h
    allow(store).to receive(:result).with(execution_id).and_raise(IOError, "result read unavailable")

    task = agent.resume_async(execution_id)
    notifications = Queue.new
    task.on_complete { |value, error| notifications << [value, error] }
    expect { task.wait_result(timeout: 5) }.to raise_error(IOError, /result read unavailable/)
    value, error = Timeout.timeout(5) { notifications.pop }
    expect(value).to be_nil
    expect(error).to be_a(IOError)
    expect(store.executions.load(execution_id).to_h).to eq(saved)
    expect(requests.length).to eq(1)
  end
end
