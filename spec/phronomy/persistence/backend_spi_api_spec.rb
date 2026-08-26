# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Persistence Backend SPI public contract" do
  subject(:persistence_class) { Phronomy::Persistence }

  class CapturingAgentRecordRepository
    attr_reader :created_record, :created_metadata

    def create(agent_id:, agent_revision:, record:)
      @created_metadata = {
        agent_id: agent_id,
        agent_revision: agent_revision
      }.freeze
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

  it "publishes the required backend capabilities" do
    expect(persistence_class::REQUIRED_CAPABILITIES).to eq(
      atomic_all: true,
      atomic_admission: true,
      optimistic_revision: true
    )
  end

  it "exposes the repository accessors and root synchronous SPI as Ruby-public" do
    expect(persistence_class.public_instance_methods).to include(
      :contents,
      :agents,
      :journals,
      :executions,
      :workflow_states,
      :transaction,
      :build_transaction_view,
      :assert_agent_watermark!
    )
  end

  it "wraps record-oriented backend repositories and passes index metadata separately" do
    contents = Object.new
    agents = CapturingAgentRecordRepository.new
    unused = Object.new

    backend_class = Class.new(Phronomy::Persistence) do
      def capabilities
        Phronomy::Persistence::REQUIRED_CAPABILITIES
      end
    end

    backend = backend_class.new(
      contents: contents,
      agents: agents,
      journals: unused,
      executions: unused,
      workflow_states: unused
    )

    root = Phronomy::Agent::AgentRoot.create(
      agent_id: "backend-spi-agent",
      agent_definition_id: "backend-spi-definition",
      agent_definition_version: 1
    )

    restored = backend.agents.create(root)

    expect(backend.contents).to equal(contents)
    expect(backend.agents).not_to equal(agents)
    expect(restored).to be_a(Phronomy::Agent::AgentRoot)
    expect(agents.created_metadata).to eq(
      agent_id: root.agent_id,
      agent_revision: root.agent_revision
    )
    expect(agents.created_record).to be_a(Phronomy::Persistence::DurableRecord)
    expect(agents.created_record.record_type).to eq("phronomy.agent_root")
    expect(agents.created_record.format_version).to eq("0.1")
  end

  it "provides one standard facade builder for transaction-scoped raw repositories" do
    raw_agents = CapturingAgentRecordRepository.new
    raw = Object.new
    watermark = CapturingWatermark.new

    backend_class = Class.new(Phronomy::Persistence) do
      def capabilities
        Phronomy::Persistence::REQUIRED_CAPABILITIES
      end
    end
    backend = backend_class.new(
      contents: raw,
      agents: raw_agents,
      journals: raw,
      executions: raw,
      workflow_states: raw
    )

    view = backend.build_transaction_view(
      contents: raw,
      agents: raw_agents,
      journals: raw,
      executions: raw,
      workflow_states: raw,
      watermark: watermark
    )

    expect(view.contents).to equal(raw)
    expect(view.agents).not_to equal(raw_agents)
    expect(
      view.assert_agent_watermark!(
        agent_id: "agent-1",
        agent_revision: 3,
        journal_position: 4
      )
    ).to be(true)
    expect(watermark.received).to eq(
      agent_id: "agent-1",
      agent_revision: 3,
      journal_position: 4
    )
  end

  it "rejects a backend that omits optimistic revision support" do
    backend_class = Class.new(Phronomy::Persistence) do
      def capabilities
        {atomic_all: true, atomic_admission: true}.freeze
      end
    end
    repository = Object.new

    expect do
      backend_class.new(
        contents: repository,
        agents: repository,
        journals: repository,
        executions: repository,
        workflow_states: repository
      )
    end.to raise_error(
      Phronomy::Persistence::UnsupportedBackendError,
      /optimistic_revision/
    )
  end

  it "exposes portable backend error classes" do
    expect(persistence_class::ConflictError).to be < Phronomy::Error
    expect(persistence_class::NotFoundError).to be < Phronomy::Error
    expect(persistence_class::UnsupportedBackendError).to be < Phronomy::Error
    expect(persistence_class::SerializationError).to be < Phronomy::Error
  end

  it "uses one immutable DurableRecord carrier for the record SPI" do
    record = Phronomy::Persistence::DurableRecord.new(
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
      Phronomy::Persistence::DurableRecord.new(
        record_type: "phronomy.example",
        payload: {"value" => 1}
      )
    end.to raise_error(
      Phronomy::Persistence::SerializationError,
      /format_version is missing/
    )
  end

  it "does not coerce DurableRecord record_type into String" do
    expect do
      Phronomy::Persistence::DurableRecord.new(
        record_type: :phronomy_example,
        format_version: "0.1",
        payload: {"value" => 1}
      )
    end.to raise_error(
      Phronomy::Persistence::SerializationError,
      /record_type must be a String/
    )
  end

  it "does not coerce DurableRecord format_version into String" do
    expect do
      Phronomy::Persistence::DurableRecord.new(
        record_type: "phronomy.example",
        format_version: 0.1,
        payload: {"value" => 1}
      )
    end.to raise_error(
      Phronomy::Persistence::SerializationError,
      /format_version must be a String/
    )
  end

  it "rejects a missing record_type in DurableRecord" do
    expect do
      Phronomy::Persistence::DurableRecord.new(
        format_version: "0.1",
        payload: {"value" => 1}
      )
    end.to raise_error(
      Phronomy::Persistence::SerializationError,
      /record_type is missing/
    )
  end

  it "rejects a missing payload in DurableRecord" do
    expect do
      Phronomy::Persistence::DurableRecord.new(
        record_type: "phronomy.example",
        format_version: "0.1"
      )
    end.to raise_error(
      Phronomy::Persistence::SerializationError,
      /payload is missing/
    )
  end

  it "rejects an empty record_type in DurableRecord" do
    expect do
      Phronomy::Persistence::DurableRecord.new(
        record_type: "",
        format_version: "0.1",
        payload: {"value" => 1}
      )
    end.to raise_error(
      Phronomy::Persistence::SerializationError,
      /record_type must not be empty/
    )
  end

  it "rejects an invalid format_version pattern in DurableRecord" do
    expect do
      Phronomy::Persistence::DurableRecord.new(
        record_type: "phronomy.example",
        format_version: "not-semver",
        payload: {"value" => 1}
      )
    end.to raise_error(
      Phronomy::Persistence::SerializationError,
      /invalid durable format_version/
    )
  end

  it "rejects a non-JSON-serializable payload in DurableRecord" do
    expect do
      Phronomy::Persistence::DurableRecord.new(
        record_type: "phronomy.example",
        format_version: "0.1",
        payload: {"value" => Float::INFINITY}
      )
    end.to raise_error(
      Phronomy::Persistence::SerializationError,
      /canonical JSON compatible/
    )
  end
end
