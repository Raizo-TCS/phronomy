# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Tool::Operation do
  let(:tool_class) do
    Class.new(Phronomy::Tool::Base) do
      tool_name "operation-contract"
      param :value, type: :string
      def execute(value:) = value
    end
  end
  let(:tool) { tool_class.new }
  let(:submitter) { double("submission connection") }

  it "executes cooperative work inline without selecting a Runtime or submission mechanism" do
    tool_class.execution_mode :cooperative
    expect(submitter).not_to receive(:submit)
    expect(Phronomy::Runtime).not_to receive(:instance)
    result = described_class.call_async(tool: tool, args: {value: "inline"}, submitter: submitter)
    expect(result).to be_done
    expect(result.wait_result).to eq("inline")
  end

  it "submits default offloaded work through the supplied connection and preserves its handle" do
    tool_class.execution_mode :offloaded
    token = Phronomy::Concurrency::CancellationToken.new
    operation = Phronomy::TaskResult.deferred
    work = nil
    expect(submitter).to receive(:submit).with(cancellation_token: token, on_full: :raise) { |&block|
      work = block
      operation
    }
    expect(Phronomy::Runtime).not_to receive(:instance)
    result = described_class.call_async(tool: tool, args: {value: "worker"}, cancellation_token: token, submitter: submitter)
    expect(result).to be(operation)
    expect(result).not_to be_done
    operation.complete(work.call)
    expect(result.wait_result).to eq("worker")
  end

  it "preserves custom async keywords, config identity and the original completion handle" do
    operation = Phronomy::TaskResult.deferred
    received = nil
    tool.define_singleton_method(:call_async) do |args, cancellation_token: nil, config: {}|
      received = [args, cancellation_token, config]
      operation
    end
    config = {suffix: "custom"}.freeze
    expect(submitter).not_to receive(:submit)
    result = described_class.call_async(tool: tool, args: {value: "custom"}, config: config, submitter: submitter)
    expect(result).to be(operation)
    expect(received).to eq([{value: "custom"}, nil, config])
    expect(received.last).to be(config)
  end

  it "allows a custom call_async to delegate to the existing Base protocol with super" do
    tool_class.execution_mode :cooperative
    tool_class.class_eval do
      def call_async(args, cancellation_token: nil, config: {})
        super.map { |result| "custom:#{result}" }
      end
    end
    expect(described_class.call_async(tool: tool, args: {value: "ok"}).wait_result).to eq("custom:ok")
  end

  it "rejects an invalid custom completion handle" do
    tool.define_singleton_method(:call_async) { |*args, **kwargs| :not_a_handle }
    expect { described_class.call_async(tool: tool, args: {}) }.to raise_error(Phronomy::ToolError, /completion handle/)
  end

  it "rejects an invalid execution mode before invoking even a custom operation" do
    allow(tool_class).to receive(:execution_mode).and_return(:invalid)
    expect(tool).not_to receive(:call_async)
    expect { described_class.call_async(tool: tool, args: {}) }.to raise_error(Phronomy::ConfigurationError, /unknown Tool execution_mode/)
  end

  it "propagates admission rejection without retrying on a different connection" do
    tool_class.execution_mode :offloaded
    error = Phronomy::BackpressureError.new("full")
    expect(submitter).to receive(:submit).once.and_raise(error)
    expect(Phronomy::Execution).not_to receive(:submit)
    expect { described_class.call_async(tool: tool, args: {}, submitter: submitter) }.to raise_error { |raised| expect(raised).to be(error) }
  end

  it "maps a custom asynchronous result without losing physical completion after cancellation" do
    source = Phronomy::Concurrency::PhysicalCompletionTask.deferred
    tool_class.define_method(:call_async) { |*args, **kwargs| source }
    transformations = []
    derived = described_class.with_result_transform(tool_class) do |value, name, args|
      transformations << [value, name, args]
      "mapped:#{value}"
    end
    result = described_class.call_async(tool: derived.new, args: {value: "late"})
    source.cancel!(Phronomy::CancellationError.new("cancelled"))
    expect { result.wait_result }.to raise_error(Phronomy::CancellationError)
    expect(result.physical_complete?).to be(false)
    expect(transformations).to be_empty
    source.mark_physical_complete!
    expect(result.physical_complete?).to be(true)
  end

  it "transforms default synchronous and asynchronous results once and retains the Tool name" do
    tool_class.execution_mode :cooperative
    calls = []
    derived = described_class.with_result_transform(tool_class) do |value, name, args|
      calls << [value, name, args]
      "mapped:#{value}"
    end
    expect(derived.new.call({value: "sync"})).to eq("mapped:sync")
    expect(described_class.call_async(tool: derived.new, args: {value: "async"}, submitter: submitter).wait_result).to eq("mapped:async")
    expect(calls).to eq([["sync", "operation-contract", {value: "sync"}], ["async", "operation-contract", {value: "async"}]])
  end
end
