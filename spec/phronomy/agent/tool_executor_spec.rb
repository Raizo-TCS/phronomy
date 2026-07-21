# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::ToolExecutor do
  # ---------------------------------------------------------------------------
  # Test doubles
  # ---------------------------------------------------------------------------
  def make_tool(mode)
    klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
      description "test tool"
      execution_mode mode
      param :x, type: :string, desc: "input"

      define_method(:execute) { |x:| "#{mode}:#{x}" }
    end
    klass.new
  end

  let(:pool_double) do
    pd = instance_double(Phronomy::Concurrency::BlockingAdapterPool)
    allow(pd).to receive(:submit) do |cancellation_token: nil, timeout: nil, &blk|
      op = double("PendingOp")
      allow(op).to receive(:wait_result).and_return(blk.call)
      op
    end
    pd
  end

  let(:runtime_with_pool) do
    r = instance_double(Phronomy::Runtime, blocking_io: pool_double)
    allow(r).to receive(:spawn) do |name: nil, &blk|
      t = double("Task-#{name}")
      allow(t).to receive(:wait_result).and_return(blk.call)
      t
    end
    r
  end

  let(:runtime_no_pool) do
    r = instance_double(Phronomy::Runtime, blocking_io: nil)
    allow(r).to receive(:spawn) do |name: nil, &blk|
      t = double("Task-no-pool-#{name}")
      allow(t).to receive(:wait_result).and_return(blk.call)
      t
    end
    r
  end

  # ---------------------------------------------------------------------------
  # :cooperative routing
  # ---------------------------------------------------------------------------
  describe "cooperative routing" do
    it "dispatches via Runtime#spawn and returns an awaitable" do
      tool = make_tool(:cooperative)
      awaitable = described_class.call_async(tool: tool, args: {"x" => "hi"},
        runtime: runtime_with_pool)
      expect(awaitable.wait_result).to eq("cooperative:hi")
      expect(pool_double).not_to have_received(:submit)
    end
  end

  # ---------------------------------------------------------------------------
  # :blocking_io routing
  # ---------------------------------------------------------------------------
  describe "blocking_io routing" do
    it "dispatches via pool.submit when a pool is present" do
      tool = make_tool(:blocking_io)
      awaitable = described_class.call_async(tool: tool, args: {"x" => "io"},
        runtime: runtime_with_pool)
      expect(awaitable.wait_result).to eq("blocking_io:io")
      expect(pool_double).to have_received(:submit).once
    end

    it "falls back to Runtime#spawn when no pool is present" do
      tool = make_tool(:blocking_io)
      awaitable = described_class.call_async(tool: tool, args: {"x" => "fallback"},
        runtime: runtime_no_pool)
      expect(awaitable.wait_result).to eq("blocking_io:fallback")
    end
  end

  # ---------------------------------------------------------------------------
  # :cpu_bound routing — warning + fallback to :blocking_io
  # ---------------------------------------------------------------------------
  describe "cpu_bound routing" do
    it "emits a deprecation-style warning and falls back to blocking_io" do
      tool = make_tool(:cpu_bound)
      expect {
        described_class.call_async(tool: tool, args: {"x" => "cpu"},
          runtime: runtime_with_pool)
      }
        .to output(/execution_mode :cpu_bound.*no dedicated executor|declares execution_mode :cpu_bound/im).to_stderr
    end

    it "still returns a result after fallback" do
      tool = make_tool(:cpu_bound)
      suppress_output = double("Logger", warn: nil)
      Phronomy.configuration.logger = suppress_output
      awaitable = described_class.call_async(tool: tool, args: {"x" => "cpu"},
        runtime: runtime_with_pool)
      expect(awaitable.wait_result).to eq("cpu_bound:cpu")
    ensure
      Phronomy.configuration.logger = nil
    end
  end

  # ---------------------------------------------------------------------------
  # :external_process routing — warning + fallback to :blocking_io
  # ---------------------------------------------------------------------------
  describe "external_process routing" do
    it "emits a warning and falls back to blocking_io" do
      tool = make_tool(:external_process)
      expect {
        described_class.call_async(tool: tool, args: {"x" => "ext"},
          runtime: runtime_with_pool)
      }
        .to output(/execution_mode :external_process|declares execution_mode :external_process/im).to_stderr
    end
  end

  # ---------------------------------------------------------------------------
  # cancellation_token propagation
  # ---------------------------------------------------------------------------
  describe "cancellation_token propagation" do
    it "passes the token to Tool#call for :cooperative tools" do
      tool = make_tool(:cooperative)
      ct = Phronomy::Concurrency::CancellationToken.new
      allow(tool).to receive(:call).and_call_original
      described_class.call_async(tool: tool, args: {"x" => "x"}, cancellation_token: ct,
        runtime: runtime_with_pool)
      expect(tool).to have_received(:call).with({"x" => "x"}, cancellation_token: ct)
    end

    it "passes the token to pool.submit for :blocking_io tools" do
      tool = make_tool(:blocking_io)
      ct = Phronomy::Concurrency::CancellationToken.new
      described_class.call_async(tool: tool, args: {"x" => "y"}, cancellation_token: ct,
        runtime: runtime_with_pool)
      expect(pool_double).to have_received(:submit).with(cancellation_token: ct, timeout: nil)
    end

    it "passes tool_timeout from config to pool.submit" do
      tool = make_tool(:blocking_io)
      described_class.call_async(tool: tool, args: {"x" => "z"},
        config: {tool_timeout: 30}, runtime: runtime_with_pool)
      expect(pool_double).to have_received(:submit).with(cancellation_token: nil, timeout: 30)
    end
  end
end
