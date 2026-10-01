# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Persistence and Storage SPI 2 public contract" do
  let(:persistence) { Phronomy::PersistenceComposition.in_memory.agent }
  let(:backend) { persistence.coordinator.backend }

  it "separates neutral transactions, domain records, and application composition" do
    stores = Phronomy::PersistenceComposition.in_memory
    expect(stores.coordinator).to respond_to(:atomic)
    expect(stores.coordinator).not_to respond_to(:agents, :teams, :workflow_states, :execution_result, :transaction)
    expect(Phronomy::Persistence).not_to respond_to(:in_memory)
    expect(stores.agent).to respond_to(:result, :runs, :transaction, :participate)
    expect(stores.agent).not_to respond_to(:teams, :team_executions, :workflow_states)
    expect(stores.multi_agent).not_to respond_to(:agents, :executions, :workflow_states)
    expect(backend.view).to respond_to(:records, :streams, :blobs, :check!)
    expect(backend).not_to respond_to(:agents, :contents, :assert_agent_watermark!)
    expect(backend.capabilities).to eq(Phronomy::Storage::Backend::REQUIRED_CAPABILITIES)
    expect(backend.capabilities[:spi_version]).to eq(2)
  end

  it "rejects old duck-typed backends before domain composition" do
    old_backend = Object.new
    def old_backend.capabilities = {atomic_all: true, atomic_admission: true, optimistic_revision: true}
    expect { Phronomy::Persistence.new(backend: old_backend) }.to raise_error(Phronomy::Persistence::UnsupportedBackendError, /SPI 2/)
  end

  it "rejects an incomplete capability declaration" do
    allow(backend).to receive(:capabilities).and_return(backend.capabilities.merge(guarded_checks: false))
    expect { Phronomy::Persistence.new(backend: backend) }.to raise_error(Phronomy::Persistence::UnsupportedBackendError, /guarded_checks/)
  end

  it "does not retain the removed eight-slot view or domain-named error alias" do
    expect(Phronomy::Storage.const_defined?(:Repositories, false)).to be(false)
    expect(Phronomy::Storage.const_defined?(:ActiveExecutionConflictError, false)).to be(false)
    expect(Phronomy::Storage::Backends::InMemory).to be < Phronomy::Storage::Backend
    expect(Phronomy::Storage::Backends::InMemory).not_to be < Phronomy::Persistence
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
