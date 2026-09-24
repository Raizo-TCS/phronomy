# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::LLMAdapter::AsyncClient do
  let(:adapter) { instance_double(Phronomy::LLMAdapter::Base) }
  let(:pool) { Phronomy::Concurrency::OffloadPool.new(pool_size: 1, queue_size: 1) }
  let(:client) { described_class.new(adapter: adapter, pool: pool) }
  let(:chat) { double("configured chat") }

  after do
    pool.shutdown(drain_timeout: 2)
  end

  it "forwards the exact chat, message and config on a worker and returns the pool task" do
    config = {custom_option: Object.new}
    received = Queue.new
    allow(adapter).to receive(:complete) do |actual_chat, message, config:|
      received << [actual_chat, message, config, Thread.current]
      :response
    end
    submitted_task = nil
    allow(pool).to receive(:submit).and_wrap_original do |method, **options, &work|
      expect(options).to eq(cancellation_token: nil, on_full: :raise)
      submitted_task = method.call(**options, &work)
    end

    result = client.complete_async(chat, nil, config: config)
    expect(result).to equal(submitted_task)
    expect(result.wait_result(timeout: 2)).to eq(:response)
    actual_chat, message, actual_config, worker = received.pop
    expect(actual_chat).to equal(chat)
    expect(message).to be_nil
    expect(actual_config).to equal(config)
    expect(worker).not_to equal(Thread.current)
  end

  it "does not start Runtime when constructed or when using an explicit pool" do
    expect(Phronomy::Runtime.default_if_initialized_for_test).to be_nil
    instance = client
    expect(Phronomy::Runtime.default_if_initialized_for_test).to be_nil
    allow(adapter).to receive(:complete).and_return(:response)
    expect(instance.complete_async(chat, "hello").wait_result(timeout: 2)).to eq(:response)
    expect(Phronomy::Runtime.default_if_initialized_for_test).to be_nil
  end

  it "resolves the current default pool again after Runtime reset" do
    instance = described_class.new(adapter: adapter)
    expect(Phronomy::Runtime.default_if_initialized_for_test).to be_nil
    allow(adapter).to receive(:complete).and_return(:response)
    expect(instance.complete_async(chat, "first").wait_result(timeout: 2)).to eq(:response)
    first_runtime = Phronomy::Runtime.instance
    Phronomy.reset_runtime!
    expect(instance.complete_async(chat, "second").wait_result(timeout: 2)).to eq(:response)
    expect(Phronomy::Runtime.instance).not_to equal(first_runtime)
  end

  it "preserves a per-call pool override without resolving Runtime" do
    allow(adapter).to receive(:complete).and_return(:response)
    instance = described_class.new(adapter: adapter)
    expect(instance.complete_async(chat, "hello", pool: pool).wait_result(timeout: 2)).to eq(:response)
    expect(Phronomy::Runtime.default_if_initialized_for_test).to be_nil
  end

  it "passes operation exceptions through the original TaskResult" do
    error = RuntimeError.new("provider failed")
    allow(adapter).to receive(:complete).and_raise(error)
    result = client.complete_async(chat, "hello")
    expect { result.wait_result(timeout: 2) }.to raise_error { |actual| expect(actual).to equal(error) }
  end

  it "raises admission failure immediately when the pool queue is full" do
    started = Queue.new
    release = Queue.new
    pool.submit {
      started << true
      release.pop
    }
    started.pop(timeout: 2)
    pool.submit(on_full: :raise) { :queued }
    expect(adapter).not_to receive(:complete)
    expect { client.complete_async(chat, "hello") }.to raise_error(Phronomy::BackpressureError)
  ensure
    release&.push(true)
  end

  it "raises when the explicit pool is shut down" do
    pool.shutdown(drain_timeout: 2)
    expect { client.complete_async(chat, "hello") }.to raise_error(Phronomy::PoolShutdownError)
  end

  it "does not run an operation whose token is already cancelled" do
    token = Phronomy::Concurrency::CancellationToken.new
    token.cancel!
    expect(adapter).not_to receive(:complete)
    result = client.complete_async(chat, "hello", config: {cancellation_token: token})
    expect { result.wait_result(timeout: 2) }.to raise_error(Phronomy::CancellationError)
    expect(result.status).to eq(:cancelled)
  end

  it "streams chunks in order and returns the adapter result" do
    config = {custom_option: Object.new}
    received = []
    allow(adapter).to receive(:stream).with(chat, nil, config: config) do |*, &sink|
      sink.call("one")
      sink.call("two")
      :done
    end
    result = client.stream_async(chat, nil, config: config) { |chunk| received << chunk }
    expect(result.wait_result(timeout: 2)).to eq(:done)
    expect(received).to eq(%w[one two])
  end

  it "checks cancellation before delivering each stream chunk" do
    token = Phronomy::Concurrency::CancellationToken.new
    received = []
    allow(adapter).to receive(:stream) do |*, &sink|
      sink.call("one")
      sink.call("two")
      :done
    end
    result = client.stream_async(chat, "hello", config: {cancellation_token: token}) do |chunk|
      received << chunk
      token.cancel! if chunk == "one"
    end
    expect { result.wait_result(timeout: 2) }.to raise_error(Phronomy::CancellationError)
    # Cancellation settles the handle before the worker necessarily exits.
    pool.shutdown(drain_timeout: 2)
    expect(result.status).to eq(:cancelled)
    expect(received).to eq(["one"])
  end

  it "requires an internal streaming sink before submitting work" do
    expect(pool).not_to receive(:submit)
    expect { client.stream_async(chat, "hello") }.to raise_error(ArgumentError, "stream_async requires a block")
  end
end
