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
end
