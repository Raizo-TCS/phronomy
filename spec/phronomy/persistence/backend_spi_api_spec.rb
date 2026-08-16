# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Persistence Backend SPI public contract" do
  subject(:persistence_class) { Phronomy::Persistence }

  it "publishes the required backend capabilities" do
    expect(persistence_class::REQUIRED_CAPABILITIES).to eq(
      atomic_all: true,
      atomic_admission: true,
      optimistic_revision: true
    )
  end

  it "exposes the synchronous transaction and durable-watermark SPI" do
    expect(persistence_class.public_instance_methods).to include(
      :transaction,
      :assert_agent_watermark!
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
end
