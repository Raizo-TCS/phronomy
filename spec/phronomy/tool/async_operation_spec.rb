# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Tool-owned asynchronous operation rules" do
  let(:source) { Phronomy::Concurrency::PhysicalCompletionTask.deferred(name: "non-agent-operation") }
  let(:tool_class) do
    Class.new(Phronomy::Tool::Base) do
      tool_name "async-number"
      execution_mode :cooperative
      param :value, type: :integer
      attr_accessor :source, :received

      def call_async(args, cancellation_token: nil, config: {})
        call_async_operation(args, cancellation_token: cancellation_token,
          operation_name: "async-number") do |validated|
          self.received = validated
          source
        end
      end
    end
  end
  let(:tool) { tool_class.new.tap { |instance| instance.source = source } }

  it "starts a non-Agent operation with coerced inputs without waiting or offloading" do
    tool_class.on_schema_error :coerce
    expect(Phronomy::Tool::ToolExecutor).not_to receive(:call_async)
    expect(source).not_to receive(:wait_result)

    result = tool.call_async({"value" => "12"})

    expect(tool.received).to eq(value: 12)
    expect(result).not_to be_done
    source.complete("ready")
    expect(result.wait_result).to eq("ready")
    expect(result.physical_complete?).to be(false)
    source.mark_physical_complete!
    expect(result.physical_complete?).to be(true)
  end

  it "returns schema failures without starting the operation" do
    expect(tool.call_async({}).wait_result).to include("Schema validation failed")
    expect(tool.received).to be_nil
  end

  it "honors strict schema policy without starting the operation" do
    tool_class.on_schema_error :raise
    expect { tool.call_async({}).wait_result }.to raise_error(Phronomy::ToolError, /schema error/)
    expect(tool.received).to be_nil
  end

  it "rejects pre-cancelled calls before validation and operation start" do
    token = Phronomy::Concurrency::CancellationToken.new.cancel!
    expect(tool).not_to receive(:validate_arguments)
    expect { tool.call_async({}, cancellation_token: token).wait_result }.to raise_error(Phronomy::CancellationError)
    expect(tool.received).to be_nil
  end

  it "rejects an implementation that returns a value instead of a completion handle" do
    tool.source = "not-a-handle"
    expect { tool.call_async({value: 1}).wait_result }.to raise_error(Phronomy::ToolError, /completion handle/)
  end

  it "applies the configured result limit after successful asynchronous completion" do
    tool_class.max_result_size 3
    result = tool.call_async({value: 1})
    source.complete("abcdef")
    expect(result.wait_result).to eq("abc...[truncated]")
  end

  it "wraps failed operations while retaining their original backtrace" do
    error = RuntimeError.new("failed")
    error.set_backtrace(["operation.rb:12"])
    result = tool.call_async({value: 1})
    source.fail(error)
    expect { result.wait_result }.to raise_error(Phronomy::ToolError, /execution failed: failed/) { |wrapped|
      expect(wrapped.backtrace).to eq(error.backtrace)
    }
  end

  it "suppresses generic failure without declaring physical completion early" do
    tool_class.on_error :suppress
    result = tool.call_async({value: 1})
    source.fail(RuntimeError.new("failed"))
    expect(result.wait_result).to eq("Tool error suppressed: failed")
    expect(result.physical_complete?).to be(false)
    source.mark_physical_complete!
    expect(result.physical_complete?).to be(true)
  end

  it "preserves Tool and cancellation errors even when suppression is configured" do
    tool_class.on_error :suppress
    [Phronomy::ToolError.new("invalid"), Phronomy::CancellationError.new("cancelled")].each do |error|
      tool.source = Phronomy::TaskResult.failed(error)
      expect { tool.call_async({value: 1}).wait_result }.to raise_error { |actual| expect(actual).to equal(error) }
    end
  end
end
