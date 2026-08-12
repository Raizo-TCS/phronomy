# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::ToolExecutor do
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
    allow(pd).to receive(:submit) do |cancellation_token: nil, on_full: :wait, **_kw, &blk|
      op = double("PendingOp")
      allow(op).to receive(:wait_result).and_return(blk.call)
      op
    end
    pd
  end

  let(:runtime_with_pool) do
    instance_double(Phronomy::Runtime, blocking_io: pool_double)
  end

  describe "cooperative routing" do
    it "dispatches via pool.submit and returns an awaitable" do
      tool = make_tool(:cooperative)
      awaitable = described_class.call_async(tool: tool, args: {"x" => "hi"},
        runtime: runtime_with_pool)
      expect(awaitable.wait_result).to eq("cooperative:hi")
      expect(pool_double).to have_received(:submit).once
    end
  end

  describe "blocking_io routing" do
    it "dispatches via pool.submit when a pool is present" do
      tool = make_tool(:blocking_io)
      awaitable = described_class.call_async(tool: tool, args: {"x" => "io"},
        runtime: runtime_with_pool)
      expect(awaitable.wait_result).to eq("blocking_io:io")
      expect(pool_double).to have_received(:submit).with(cancellation_token: nil, on_full: anything).once
    end
  end

  describe "cpu_bound routing" do
    it "raises ConfigurationError for :cpu_bound tools" do
      tool = make_tool(:cpu_bound)
      expect {
        described_class.call_async(tool: tool, args: {"x" => "cpu"},
          runtime: runtime_with_pool)
      }.to raise_error(Phronomy::ConfigurationError, /cpu_bound/)
    end
  end

  describe "external_process routing" do
    it "raises ConfigurationError for :external_process tools" do
      tool = make_tool(:external_process)
      expect {
        described_class.call_async(tool: tool, args: {"x" => "ext"},
          runtime: runtime_with_pool)
      }.to raise_error(Phronomy::ConfigurationError, /external_process/)
    end
  end

  describe "cancellation_token propagation" do
    it "passes cancellation_token to pool.submit" do
      tool = make_tool(:blocking_io)
      ct = Phronomy::Concurrency::CancellationToken.new
      described_class.call_async(tool: tool, args: {"x" => "y"}, cancellation_token: ct,
        runtime: runtime_with_pool)
      expect(pool_double).to have_received(:submit).with(cancellation_token: ct, on_full: anything)
    end

    it "passes cancellation_token to Tool#call inside the worker" do
      tool = make_tool(:blocking_io)
      ct = Phronomy::Concurrency::CancellationToken.new
      allow(tool).to receive(:call).and_call_original
      described_class.call_async(tool: tool, args: {"x" => "x"}, cancellation_token: ct,
        runtime: runtime_with_pool)
      expect(tool).to have_received(:call).with({"x" => "x"}, cancellation_token: ct)
    end
  end
end
