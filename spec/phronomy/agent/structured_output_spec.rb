# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent structured output contract" do
  let(:schema) do
    {type: "object", properties: {answer: {type: "string"}, score: {type: "number", minimum: 0, maximum: 1}},
     required: %w[answer score], additionalProperties: false}
  end
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "structured-output-acceptance", version: 1
    end
  end
  let(:store) { Phronomy::PersistenceComposition.in_memory.agent }
  let(:agent) { agent_class.create(persistence: store) }
  let(:requests) { [] }
  let(:responses) { [Phronomy::LLMAdapter::Response.new(content: '{"answer":"ok","score":0.8}', finish_reason: :stop)] }

  before do
    queue = responses
    captured = requests
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |request, cancellation_token:|
        captured << request
        queue.shift || raise("unexpected LLM replay")
      end
      define_method(:perform_stream) do |request, cancellation_token:, &block|
        block.call(Phronomy::LLMAdapter::StreamChunk.new(content: "partial"))
        perform_complete(request, cancellation_token: cancellation_token)
      end
    end.new
    Phronomy.configure { |config| config.llm_adapter = adapter }
  end

  it "returns a frozen JSON value and re-observes it without another LLM call (F0/F4 durable facts)" do
    result = agent.invoke("question", output_schema: schema)
    expect(result[:output]).to eq("answer" => "ok", "score" => 0.8)
    expect(result[:output]).to be_frozen
    expect(result[:raw_output]).to eq('{"answer":"ok","score":0.8}')
    saved = store.executions.load(result[:execution_id])
    expect(saved.metadata.dig("output_contract", "version")).to eq(1)
    manifest = store.contents.fetch_json(saved.llm_calls.first.manifest_ref)
    expect(manifest["response_schema_ref"]).to eq(saved.metadata.dig("output_contract", "schema_ref"))
    agent.unload!
    loaded = agent_class.load(agent.agent_id, persistence: store)
    observed = loaded.resume(result[:execution_id])
    expect(observed[:output]).to eq(result[:output])
    expect(observed[:raw_output]).to eq(result[:raw_output])
    expect(requests.length).to eq(1)
  end

  [[:stop, nil, "not JSON", "agent.output_invalid", "invalid_json"],
    [:stop, nil, '{"answer":"ok","score":2}', "agent.output_invalid", "schema_mismatch"],
    [:length, nil, '{"answer":"ok","score":0.8}', "agent.output_incomplete", "length"],
    [:unknown, nil, "{}", "agent.output_incomplete", "unknown_finish_reason"],
    [:stop, "refused", "{}", "agent.output_refused", "model_refusal"]].each do |finish, refusal, content, code, reason|
    it "persists #{reason} and restores the owned error without replay" do
      responses.replace([Phronomy::LLMAdapter::Response.new(content: content, finish_reason: finish, refusal: refusal)])
      error = nil
      expect { agent.invoke("question", output_schema: schema) }.to raise_error(Phronomy::Agent::OutputError) { |e| error = e }
      expect(error.code).to eq(code)
      expect(error.reason).to eq(reason)
      expect(error.raw_output).to eq(content)
      expect(store.executions.load(error.execution_id).status).to eq(:failed)
      agent.unload!
      loaded = agent_class.load(agent.agent_id, persistence: store)
      expect { loaded.resume(error.execution_id) }.to raise_error(Phronomy::Agent::OutputError) { |e|
        expect(e.reason).to eq(reason)
        expect(e.raw_output).to eq(content)
      }
      expect(requests.length).to eq(1)
    end
  end

  it "rejects configuration before calling the model" do
    expect { agent.invoke("q", output_schema: {type: "object", bogus: true}) }.to raise_error(ArgumentError)
    expect(requests).to be_empty
  end

  it "keeps freeform invocation unchanged" do
    expect(agent.invoke("question")[:output]).to eq('{"answer":"ok","score":0.8}')
    expect(requests.first.response_schema).to be_nil
  end

  it "validates the final public output after output filters" do
    agent.add_output_filter(->(_text) { '{"answer":"bad","score":9}' })
    expect { agent.invoke("q", output_schema: schema) }.to raise_error(Phronomy::Agent::OutputError, /schema_mismatch/)
  end
  [:stop, :length, :content_filter].each do |finish|
    it "makes streamed #{finish} final Task and terminal events agree" do
      responses.replace([Phronomy::LLMAdapter::Response.new(content: '{"answer":"ok","score":0.8}', finish_reason: finish)])
      events = []
      streaming_agent = agent_class.create(persistence: store, on_event: ->(event) { events << event })
      task = streaming_agent.stream_async("q", output_schema: schema)
      if finish == :stop
        expect(task.wait_result[:output]).to eq("answer" => "ok", "score" => 0.8)
      else
        expect { task.wait_result }.to raise_error(Phronomy::Agent::OutputError) { |error| expect(error.reason).to eq(finish.to_s) }
      end
      terminal = events.select { |event| [:done, :error].include?(event.type) }
      expect(terminal.map(&:type)).to eq([(finish == :stop) ? :done : :error])
    end
  end

  it "persists all finite JSON numbers without imposing canonical-domain limits" do
    value = {"large" => 10**30, "signed_zero" => -0.0}
    numeric_schema = {type: "object", properties: {large: {type: "integer"}, signed_zero: {type: "number"}}, required: %w[large signed_zero]}
    responses.replace([Phronomy::LLMAdapter::Response.new(content: JSON.generate(value), finish_reason: :stop)])
    result = agent.invoke("q", output_schema: numeric_schema)
    expect(agent.resume(result[:execution_id])[:output]).to eq(value)
    expect(1.0 / result[:output]["signed_zero"]).to eq(-Float::INFINITY)
  end

  it "allows independent schemas on successive executions of the same Agent" do
    responses << Phronomy::LLMAdapter::Response.new(content: '{"other":1}', finish_reason: :stop)
    first = agent.invoke("q", output_schema: schema)
    second = agent.invoke("q2", output_schema: {type: "object", properties: {other: {type: "integer"}}, required: ["other"]})
    expect(first[:output].keys).to eq(%w[answer score])
    expect(second[:output]).to eq("other" => 1)
    expect(requests.map(&:response_schema).uniq.length).to eq(2)
  end
end
