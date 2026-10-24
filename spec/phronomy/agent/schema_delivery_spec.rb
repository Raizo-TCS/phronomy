# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent schema delivery symmetry" do
  let(:schema) { {type: "object", properties: {answer: {type: "string"}}, required: ["answer"], additionalProperties: false} }
  let(:store) { Phronomy::PersistenceComposition.in_memory.agent }
  let(:events) { [] }
  let(:agent_class) { Class.new(Phronomy::Agent::Base) { agent_definition id: "schema-delivery", version: 1 } }
  let(:agent) { agent_class.create(persistence: store, on_event: events.method(:<<)) }
  let(:requests) { [] }
  let(:responses) { [Phronomy::LLMAdapter::Response.new(content: '{"answer":"ok"}', finish_reason: :stop)] }

  before do
    captured, queue = requests, responses
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |request, cancellation_token:|
        captured << request
        result = queue.shift || raise("unexpected replay")
        raise result if result.is_a?(Exception)
        result
      end
      define_method(:perform_stream) do |request, cancellation_token:, &block|
        block.call(Phronomy::LLMAdapter::StreamChunk.new(content: "provisional"))
        perform_complete(request, cancellation_token: cancellation_token)
      end
    end.new
    Phronomy.configure { |config| config.llm_adapter = adapter }
  end

  %i[native none].each do |delivery|
    %i[invoke invoke_async stream stream_async].each do |entry|
      it "uses #{delivery} consistently through #{entry}" do
        value = agent.public_send(entry, "question", output_schema: schema, schema_delivery: delivery)
        result = value.is_a?(Phronomy::TaskResult) ? value.wait_result : value
        expect(result[:output]).to eq("answer" => "ok")
        expect(result[:output]).to be_frozen
        expect(result[:output]["answer"]).to be_frozen
        expect(result[:raw_output]).to eq('{"answer":"ok"}')
        expect(requests.length).to eq(1)
        expect(requests.first.response_schema).to eq((delivery == :native) ? JSON.parse(schema.to_json) : nil)
        saved = store.executions.load(result[:execution_id])
        expect(saved.metadata.fetch("output_contract")).to include("version" => 2, "schema_delivery" => delivery.to_s)
        expect(store.contents.fetch_json(saved.metadata.dig("output_contract", "schema_ref"))).to eq(JSON.parse(schema.to_json))
        expect(agent.resume(result[:execution_id])[:output]).to eq(result[:output])
        expect(requests.length).to eq(1)
      end
    end

    [["not JSON", :stop, nil, "invalid_json"],
      ['{"answer":1}', :stop, nil, "schema_mismatch"],
      ['{"answer":"one","answer":"two"}', :stop, nil, "invalid_json"],
      ["```json\n{\"answer\":\"ok\"}\n```", :stop, nil, "invalid_json"],
      ['{"answer":"ok"}', :length, nil, "length"],
      ['{"answer":"ok"}', :unknown, nil, "unknown_finish_reason"],
      ['{"answer":"ok"}', :stop, "denied", "model_refusal"]].each do |content, finish, refusal, reason|
      it "preserves #{reason} with #{delivery}, without repairing or retrying" do
        responses.replace([Phronomy::LLMAdapter::Response.new(content: content, finish_reason: finish, refusal: refusal)])
        expect { agent.stream("q", output_schema: schema, schema_delivery: delivery) }
          .to raise_error(Phronomy::Agent::OutputError) { |error|
            expect(error.reason).to eq(reason)
            expect(error.raw_output).to eq(content)
          }
        expect(requests.length).to eq(1)
        expect(events.map(&:type)).to include(:token, :error)
        expect(events.map(&:type)).not_to include(:done)
      end
    end
  end

  %i[invoke invoke_async stream stream_async].each do |entry|
    it "rejects invalid #{entry} options before durable admission or provider work" do
      [{schema_delivery: :none}, {schema_delivery: :native}, {output_schema: schema, schema_delivery: :auto},
        {output_schema: schema, schema_delivery: false}, {config: {schema_delivery: :none}},
        {config: {"schema_delivery" => "none"}}].each do |options|
        expect { agent.public_send(entry, "q", **options) }.to raise_error(ArgumentError)
      end
      expect(store.runs(agent.agent_id)).to be_empty
      expect(requests).to be_empty
    end
  end

  it "forwards run_once options without adding a second execution" do
    result = Phronomy::Agent.run_once(definition: agent_class, input: "q", output_schema: schema, schema_delivery: :none)
    expect(result[:output]).to eq("answer" => "ok")
    expect(requests.map(&:response_schema)).to eq([nil])
  end

  it "rejects changed schema or delivery for a reserved identity before another POST" do
    reservation = Phronomy::Agent::ReservedExecution.new(agent_id: agent.agent_id, execution_id: "reserved-json")
    first = agent.start_reserved_async(reservation: reservation, input: "q", output_schema: schema, schema_delivery: :none).wait_result
    expect(agent.start_reserved_async(reservation: reservation, input: "q", output_schema: schema, schema_delivery: :none).wait_result[:output]).to eq(first[:output])
    [{output_schema: schema, schema_delivery: :native}, {output_schema: {type: "object"}, schema_delivery: :none}].each do |options|
      expect { agent.start_reserved_async(reservation: reservation, input: "q", **options).wait_result }
        .to raise_error(Phronomy::Persistence::StateConflictError, /output contract mismatch/)
    end
    expect(requests.length).to eq(1)
  end

  it "keeps version-one durable metadata native and rejects unknown versions and modes" do
    contract = Phronomy::Agent::OutputContract.new(schema)
    saved = contract.metadata(store.contents).fetch("output_contract")
    legacy = saved.except("schema_delivery").merge("version" => 1)
    execution = Struct.new(:metadata).new({"output_contract" => legacy})
    restored = Phronomy::Agent::OutputContract.restore(execution, store.contents)
    expect(restored.schema_delivery).to eq(:native)
    expect(restored.digest).to eq(contract.digest)
    expect(legacy).to eq(saved.except("schema_delivery").merge("version" => 1))
    [saved.merge("version" => 3), saved.merge("schema_delivery" => "auto")].each do |invalid|
      execution.metadata = {"output_contract" => invalid}
      expect { Phronomy::Agent::OutputContract.restore(execution, store.contents) }.to raise_error(ArgumentError)
    end
  end

  [{params: {response_format: {type: "json_object"}}}, {params: {schema_delivery: "native"}},
    {text: {format: {type: "json_schema"}}}, {output_config: {format: {type: "json_schema"}}}].each do |patch|
    it "rejects provider schema overrides in #{patch.keys} while using local validation" do
      agent.before_llm_input = ->(_context) {
        Phronomy::Context::LLMInputPatch.new(model_config_patch: patch)
      }
      expect { agent.invoke("q", output_schema: schema, schema_delivery: :none) }.to raise_error(ArgumentError, /cannot override/)
      expect(requests).to be_empty
    end
  end

  it "uses a new execution envelope that a version-0.2 reader rejects" do
    result = agent.invoke("q", output_schema: schema, schema_delivery: :none)
    execution = store.executions.load(result[:execution_id])
    codec = Phronomy::Agent::Persistence::Codec
    record = codec.encode_agent_execution(execution)
    expect(record.format_version).to eq("0.3")
    expect(codec.decode_agent_execution(record).metadata).to eq(execution.metadata)
    expect {
      codec.send(:current_payload!, record, record_type: codec::AGENT_EXECUTION_RECORD_TYPE,
        format_version: "0.2", keys: codec::AGENT_EXECUTION_KEYS, label: "old reader")
    }.to raise_error(Phronomy::Storage::SerializationError, /format version/)
    mislabeled = Phronomy::Storage::DurableRecord.new(record_type: record.record_type, format_version: "0.2", payload: record.payload)
    expect { codec.decode_agent_execution(mislabeled) }.to raise_error(Phronomy::Storage::SerializationError, /output contract/)
  end

  it "keeps provider failures distinct from local validation and does not fall back" do
    failure = Phronomy::LLMAdapter::TransportError.new("provider failed")
    responses.replace([failure])
    expect { agent.invoke("q", output_schema: schema, schema_delivery: :none) }.to raise_error { |error| expect(error).to equal(failure) }
    expect(requests.length).to eq(1)
  end
end
