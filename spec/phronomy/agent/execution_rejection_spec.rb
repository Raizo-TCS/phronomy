# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Reserved Agent start rejection" do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "execution-rejection", version: 1
    end
  end
  let(:store) { Phronomy::PersistenceComposition.in_memory.agent }
  let(:agent) { agent_class.create(persistence: store) }
  let(:reservation) { Phronomy::Agent::ReservedExecution.new(agent_id: agent.agent_id, execution_id: "reserved-rejection") }
  let(:requests) { [] }

  before do
    captured = requests
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |request, cancellation_token:|
        captured << request
        Phronomy::LLMAdapter::Response.new(content: "answer", finish_reason: :stop)
      end
    end.new
    Phronomy.configure { |config| config.llm_adapter = adapter }
  end

  def expect_rejection(task, cause_class, message)
    expect { task.wait_result(timeout: 5) }.to raise_error(Phronomy::Agent::ExecutionRejectedError, message) { |error|
      expect(error.agent_id).to eq(agent.agent_id)
      expect(error.execution_id).to eq(reservation.execution_id)
      expect(error.code).to eq("agent.execution_rejected")
      expect(error.cause).to be_a(cause_class)
      expect(Phronomy::Error.diagnostic(error).fetch("cause")).to include("class" => cause_class.name)
    }
    expect(store.observe_execution(agent_id: agent.agent_id, execution_id: reservation.execution_id)).to be_absent
    expect(store.agents.load(agent.agent_id).lifecycle_status).to eq(:idle)
    expect(requests).to be_empty
  end

  it "identifies a durable-context rejection without creating an Execution" do
    task = agent.start_reserved_async(reservation: reservation, input: "question", config: {durable_context: "invalid"})
    expect_rejection(task, ArgumentError, /canonical JSON-compatible Hash/)
    expect(agent.start_reserved_async(reservation: reservation, input: "question", config: {durable_context: {"valid" => true}})
      .wait_result(timeout: 5)).to include(status: :completed)
  end

  it "identifies noncanonical durable context without changing ordinary invoke errors" do
    expect { agent.invoke("question", config: {durable_context: "invalid"}) }.to raise_error(ArgumentError)
    task = agent.start_reserved_async(reservation: reservation, input: "question", config: {durable_context: {"invalid" => Object.new}})
    expect_rejection(task, ArgumentError, /unsupported Phronomy Canonical JSON/)
  end

  it "identifies input extraction failure before admission" do
    allow(agent).to receive(:extract_message).and_raise(IOError, "input extraction rejected")
    expect_rejection(agent.start_reserved_async(reservation: reservation, input: "question"),
      IOError, /input extraction rejected/)
  end

  it "identifies invalid preparation metadata before admission" do
    agent_class.max_iterations(-1)
    expect_rejection(agent.start_reserved_async(reservation: reservation, input: "question"),
      ArgumentError, /max_iterations/)
    expect { agent.invoke("question") }.to raise_error(ArgumentError, /max_iterations/)
  end

  it "keeps hosted start validation on its existing exception contract" do
    expect { agent.start_hosted(reservation: reservation, input: "question", config: {durable_context: "invalid"}) }
      .to raise_error(ArgumentError, /canonical JSON-compatible Hash/)
  end

  it "does not reclassify an execution read failure by its exception type" do
    id = reservation.execution_id
    allow(store.executions).to receive(:load).with(id).and_raise(Phronomy::ConfigurationError, "read unavailable")
    expect { agent.start_reserved_async(reservation: reservation, input: "question").wait_result(timeout: 5) }
      .to raise_error(Phronomy::ConfigurationError, /read unavailable/)
    expect(requests).to be_empty
  end

  [IOError, Phronomy::ConfigurationError, ArgumentError].each do |error_class|
    it "does not report a lost admission response as rejection when it raises #{error_class}" do
      id = reservation.execution_id
      armed = true
      allow(store.coordinator).to receive(:atomic).and_wrap_original do |original, &operation|
        value = original.call(&operation)
        execution = begin
          store.executions.load(id)
        rescue Phronomy::Persistence::NotFoundError
          nil
        end
        if armed && execution&.status == :preparing
          armed = false
          raise error_class, "admission response lost"
        end
        value
      end

      expect { agent.start_reserved_async(reservation: reservation, input: "question").wait_result(timeout: 5) }
        .to raise_error(Phronomy::Agent::InitialPreparationRecoveryError) { |error|
          expect(error.original_error).to be_a(error_class)
          expect(error.original_error.message).to include("admission response lost")
          expect(error.recovery).to equal(agent.pending_initial_preparation_recovery)
        }
      expect(store.executions.load(id).status).to eq(:preparing)
      expect(requests).to be_empty
    end
  end

  it "keeps a cancellation request distinct from a validation rejection" do
    token = Phronomy::Concurrency::CancellationToken.new
    token.cancel!
    expect {
      agent.start_reserved_async(reservation: reservation, input: "question", config: {cancellation_token: token})
        .wait_result(timeout: 5)
    }.to raise_error(Phronomy::CancellationError)
    expect(store.observe_execution(agent_id: agent.agent_id, execution_id: reservation.execution_id)).to be_absent
    expect(requests).to be_empty
  end
end
