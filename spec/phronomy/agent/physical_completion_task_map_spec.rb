# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Concurrency::PhysicalCompletionTask do
  it "keeps mapped physical completion pending after early cancellation until the worker returns" do
    started = Queue.new
    release = Queue.new
    physical = Queue.new
    token = Phronomy::Concurrency::CancellationToken.new
    pool = Phronomy::Concurrency::OffloadPool.new(pool_size: 1, queue_size: 2)

    source = pool.submit(cancellation_token: token) do
      started << true
      release.pop
      :late_value
    end
    mapped = source.map { |value| "mapped:#{value}" }
    mapped.on_physical_complete { physical << true }
    started.pop

    token.cancel!

    expect(mapped).to be_done
    expect(mapped.physical_complete?).to be false
    expect { mapped.wait_result }.to raise_error(Phronomy::CancellationError)

    release << true
    physical.pop

    expect(source.physical_complete?).to be true
    expect(mapped.physical_complete?).to be true
  ensure
    release << true if defined?(release) && release.empty?
    pool&.shutdown(drain_timeout: 1)
  end

  it "does not mark the mapped Task physically complete while the mapping callback is still running" do
    mapping_started = Queue.new
    mapping_release = Queue.new
    pool = Phronomy::Concurrency::OffloadPool.new(pool_size: 1, queue_size: 2)

    source = pool.submit { :source_value }
    mapped = source.map do |value|
      mapping_started << true
      mapping_release.pop
      "mapped:#{value}"
    end

    mapping_started.pop

    expect(source.physical_complete?).to be true
    expect(mapped.physical_complete?).to be false

    mapping_release << true

    expect(mapped.wait_result).to eq("mapped:source_value")
    expect(mapped.physical_complete?).to be true
  ensure
    mapping_release << true if defined?(mapping_release) && mapping_release.empty?
    pool&.shutdown(drain_timeout: 1)
  end

  it "raises ArgumentError when on_physical_complete is called without a block" do
    task = described_class.deferred(name: "test")
    expect { task.on_physical_complete }.to raise_error(ArgumentError, /requires a block/)
  end

  it "delivers on_physical_complete immediately when the task is already physically complete" do
    task = described_class.deferred(name: "test")
    task.mark_physical_complete!
    delivered = false
    task.on_physical_complete { delivered = true }
    expect(delivered).to be true
  end

  it "raises ArgumentError when map is called without a block" do
    task = described_class.deferred(name: "test")
    expect { task.map }.to raise_error(ArgumentError, /requires a block/)
  end

  it "tolerates a raising on_physical_complete callback when no logger is configured" do
    task = described_class.deferred(name: "test")
    task.on_physical_complete { raise "callback failure" }
    # Should not propagate the error; fires the else branch of logger&.error
    expect { task.mark_physical_complete! }.not_to raise_error
  end

  it "logs a raising on_physical_complete callback when a logger is configured" do
    logger = instance_double(Logger, error: nil)
    allow(Phronomy.configuration).to receive(:logger).and_return(logger)

    task = described_class.deferred(name: "test")
    task.on_physical_complete { raise "callback failure" }
    task.mark_physical_complete!

    expect(logger).to have_received(:error)
  end
end
