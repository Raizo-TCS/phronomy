# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::RuntimeSettings do
  it "exposes live public configuration writes through a narrow settings object" do
    logger = Object.new
    tracer = Object.new
    Phronomy.configure do |config|
      config.logger = logger
      config.tracer = tracer
      config.trace_pii = true
      config.event_loop_stop_grace_seconds = 3
      config.event_loop_starvation_threshold_seconds = 0.25
      config.event_loop_dispatch_threshold_seconds = 0.5
      config.offload_pool_size = 2
      config.offload_queue_size = 7
    end

    settings = described_class.current
    expect(settings).not_to be_a(Phronomy::Configuration)
    expect(settings).not_to respond_to(:llm_adapter, :before_llm_input, :persistence)
    expect(settings.logger).to equal(logger)
    expect(settings.tracer).to equal(tracer)
    expect(settings.trace_pii).to be(true)
    expect(settings.event_loop_stop_grace_seconds).to eq(3)
    expect(settings.event_loop_starvation_threshold_seconds).to eq(0.25)
    expect(settings.event_loop_dispatch_threshold_seconds).to eq(0.5)
    pool = Phronomy::Runtime.instance.offload
    expect(pool.pool_size).to eq(2)
    expect(pool.queue_size).to eq(7)
    Phronomy.configuration.logger = nil
    expect(described_class.current.logger).to be_nil
  end

  it "follows replacement by reset_configuration! without retaining stale settings" do
    previous = described_class.current
    Phronomy.configuration.offload_pool_size = 2
    Phronomy.reset_configuration!

    expect(described_class.current).not_to equal(previous)
    expect(described_class.current.offload_pool_size).to eq(10)
    expect(previous.offload_pool_size).to eq(2)
  end

  it "restores nested scoped scalar settings and component identities after failure" do
    tracer = Phronomy.configuration.tracer
    logger = Object.new
    Phronomy.configuration.logger = logger

    expect {
      Phronomy.with_configuration do |outer|
        outer.offload_pool_size = 3
        outer.trace_pii = true
        Phronomy.with_configuration do |inner|
          inner.offload_pool_size = 1
          inner.tracer = Object.new
          inner.logger = nil
          expect(described_class.current.offload_pool_size).to eq(1)
        end
        expect(described_class.current.offload_pool_size).to eq(3)
        expect(described_class.current.trace_pii).to be(true)
        expect(described_class.current.tracer).to equal(tracer)
        expect(described_class.current.logger).to equal(logger)
        raise "scope failed"
      end
    }.to raise_error("scope failed")

    expect(described_class.current.offload_pool_size).to eq(10)
    expect(described_class.current.trace_pii).to be(false)
    expect(described_class.current.tracer).to equal(tracer)
    expect(described_class.current.logger).to equal(logger)
  end

  it "duplicates scalar settings while retaining injected component identities" do
    original = Phronomy.configuration
    copied = original.dup
    copied.offload_pool_size = 1
    copied.trace_pii = true
    copied.tracer = Object.new

    expect(original.offload_pool_size).to eq(10)
    expect(original.trace_pii).to be(false)
    expect(copied.tracer).not_to equal(original.tracer)
    expect(copied.llm_adapter).to equal(original.llm_adapter)
    expect(copied.logger).to equal(original.logger)
  end
end
