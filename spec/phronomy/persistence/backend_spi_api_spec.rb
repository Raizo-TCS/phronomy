# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Persistence and Storage Backend SPI public contract" do
  class CapturingAgentRecordRepository
    attr_reader :created_record, :created_metadata

    def create(agent_id:, agent_revision:, record:)
      @created_metadata = {agent_id: agent_id, agent_revision: agent_revision}.freeze
      @created_record = record
      record
    end
  end

  class CapturingWatermark
    attr_reader :received

    def assert_agent_watermark!(**kwargs)
      @received = kwargs.freeze
      true
    end
  end

  let(:backend_class) do
    Class.new(Phronomy::Storage::Backend) do
      attr_accessor :transaction_view

      def capabilities = Phronomy::Storage::Backend::REQUIRED_CAPABILITIES

      def transaction
        yield transaction_view
      end
    end
  end
  let(:raw) { Object.new }
  let(:raw_agents) { CapturingAgentRecordRepository.new }
  let(:raw_repositories) do
    {contents: raw, agents: raw_agents, journals: raw, executions: raw,
     workflow_states: raw, handoff_states: raw, teams: raw, team_executions: raw}
  end
  let(:backend) { backend_class.new(**raw_repositories) }
  let(:persistence) { Phronomy::Persistence.new(backend: backend) }
  let(:root) do
    Phronomy::Agent::AgentRoot.create(agent_id: "backend-spi-agent",
      agent_definition_id: "backend-spi-definition", agent_definition_version: 1)
  end

  it "publishes the required storage capabilities" do
    expect(Phronomy::Storage::Backend::REQUIRED_CAPABILITIES).to eq(
      atomic_all: true, atomic_admission: true, optimistic_revision: true
    )
  end

  it "exposes both domain and record repository protocols" do
    required = [:contents, :agents, :journals, :executions, :workflow_states,
      :handoff_states, :teams, :team_executions, :transaction, :assert_agent_watermark!]
    expect(Phronomy::Persistence.public_instance_methods).to include(*required)
    expect(Phronomy::Storage::Backend.public_instance_methods).to include(*required)
    expect(persistence.backend).to equal(backend)
    expect(persistence.capabilities).to eq(backend.capabilities)
  end

  it "wraps raw repositories and passes identity metadata separately" do
    restored = persistence.agents.create(root)
    expect(persistence.contents).to equal(raw)
    expect(backend.agents).to equal(raw_agents)
    expect(restored).to be_a(Phronomy::Agent::AgentRoot)
    expect(raw_agents.created_metadata).to eq(agent_id: root.agent_id, agent_revision: 0)
    expect(raw_agents.created_record).to be_a(Phronomy::Storage::DurableRecord)
    expect(raw_agents.created_record.record_type).to eq("phronomy.agent_root")
    expect(raw_agents.created_record.format_version).to eq("0.1")
  end

  it "uses transaction-scoped repositories and watermark instead of the root view" do
    tx_agents = CapturingAgentRecordRepository.new
    tx_contents = Object.new
    watermark = CapturingWatermark.new
    backend.transaction_view = Phronomy::Storage::Repositories.new(
      **raw_repositories.merge(agents: tx_agents, contents: tx_contents), watermark: watermark
    )
    result = persistence.transaction do |tx|
      expect(tx.contents).to equal(tx_contents)
      expect(tx.agents.create(root)).to be_a(Phronomy::Agent::AgentRoot)
      expect(tx.assert_agent_watermark!(agent_id: root.agent_id,
        agent_revision: 3, journal_position: 4)).to be(true)
      :transaction_result
    end
    expect(result).to eq(:transaction_result)
    expect(tx_agents.created_metadata).to eq(agent_id: root.agent_id, agent_revision: 0)
    expect(raw_agents.created_record).to be_nil
    expect(watermark.received).to eq(agent_id: root.agent_id, agent_revision: 3, journal_position: 4)
  end

  it "rejects a missing capability before exposing domain repositories" do
    allow(backend).to receive(:capabilities).and_return(atomic_all: true, atomic_admission: true)
    expect { persistence }.to raise_error(Phronomy::Storage::UnsupportedBackendError, /optimistic_revision/)
  end

  it "publishes storage errors without an upper Persistence owner" do
    [Phronomy::Storage::ConflictError, Phronomy::Storage::NotFoundError,
      Phronomy::Storage::SerializationError, Phronomy::Storage::UnsupportedBackendError].each do |error|
      expect(error).to be < Phronomy::Error
    end
  end

  it "removes the replaced inheritance and facade-building SPI" do
    expect(Phronomy::Storage::Backends::InMemory).to be < Phronomy::Storage::Backend
    expect(Phronomy::Storage::Backends::InMemory).not_to be < Phronomy::Persistence
    expect(persistence).not_to respond_to(:build_transaction_view)
    expect(backend).not_to respond_to(:build_transaction_view)
    [:InMemory, :DurableRecord, :ConflictError, :NotFoundError,
      :SerializationError, :UnsupportedBackendError, :REQUIRED_CAPABILITIES].each do |name|
      expect(Phronomy::Persistence.const_defined?(name, false)).to be(false)
    end
  end

  it "uses one immutable DurableRecord carrier for the record SPI" do
    record = Phronomy::Storage::DurableRecord.new(
      record_type: "phronomy.example",
      format_version: "0.1",
      payload: {"value" => [1, "two"]}
    )

    expect(record).to be_frozen
    expect(record.payload).to be_frozen
    expect(record.payload.fetch("value")).to be_frozen
    expect(record.copy.payload).to eq(record.payload)
  end

  it "reports a missing format version as SerializationError" do
    expect do
      Phronomy::Storage::DurableRecord.new(
        record_type: "phronomy.example",
        payload: {"value" => 1}
      )
    end.to raise_error(
      Phronomy::Storage::SerializationError,
      /format_version is missing/
    )
  end

  it "does not coerce DurableRecord record_type into String" do
    expect do
      Phronomy::Storage::DurableRecord.new(
        record_type: :phronomy_example,
        format_version: "0.1",
        payload: {"value" => 1}
      )
    end.to raise_error(
      Phronomy::Storage::SerializationError,
      /record_type must be a String/
    )
  end

  it "does not coerce DurableRecord format_version into String" do
    expect do
      Phronomy::Storage::DurableRecord.new(
        record_type: "phronomy.example",
        format_version: 0.1,
        payload: {"value" => 1}
      )
    end.to raise_error(
      Phronomy::Storage::SerializationError,
      /format_version must be a String/
    )
  end

  it "rejects a missing record_type in DurableRecord" do
    expect do
      Phronomy::Storage::DurableRecord.new(
        format_version: "0.1",
        payload: {"value" => 1}
      )
    end.to raise_error(
      Phronomy::Storage::SerializationError,
      /record_type is missing/
    )
  end

  it "rejects a missing payload in DurableRecord" do
    expect do
      Phronomy::Storage::DurableRecord.new(
        record_type: "phronomy.example",
        format_version: "0.1"
      )
    end.to raise_error(
      Phronomy::Storage::SerializationError,
      /payload is missing/
    )
  end

  it "rejects an empty record_type in DurableRecord" do
    expect do
      Phronomy::Storage::DurableRecord.new(
        record_type: "",
        format_version: "0.1",
        payload: {"value" => 1}
      )
    end.to raise_error(
      Phronomy::Storage::SerializationError,
      /record_type must not be empty/
    )
  end

  it "rejects an invalid format_version pattern in DurableRecord" do
    expect do
      Phronomy::Storage::DurableRecord.new(
        record_type: "phronomy.example",
        format_version: "not-semver",
        payload: {"value" => 1}
      )
    end.to raise_error(
      Phronomy::Storage::SerializationError,
      /invalid durable format_version/
    )
  end

  it "rejects a non-JSON-serializable payload in DurableRecord" do
    expect do
      Phronomy::Storage::DurableRecord.new(
        record_type: "phronomy.example",
        format_version: "0.1",
        payload: {"value" => Float::INFINITY}
      )
    end.to raise_error(
      Phronomy::Storage::SerializationError,
      /canonical JSON compatible/
    )
  end
end
