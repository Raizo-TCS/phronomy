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
    pool = instance_double(Phronomy::Concurrency::OffloadPool)
    allow(pool).to receive(:submit) do |cancellation_token: nil, on_full: :raise, **_kw, &block|
      task = Phronomy::Task.deferred(name: "offload-double")
      begin
        task.complete(block.call)
      rescue => error
        task.fail(error)
      end
      task
    end
    pool
  end

  let(:runtime_with_pool) do
    instance_double(Phronomy::Runtime, offload: pool_double)
  end

  describe "cooperative routing" do
    it "executes inline and returns an already-settled Task without using OffloadPool" do
      tool = make_tool(:cooperative)
      task = described_class.call_async(
        tool: tool,
        args: {"x" => "hi"},
        runtime: runtime_with_pool
      )

      expect(task).to be_a(Phronomy::Task)
      expect(task).to be_done
      expect(task.wait_result).to eq("cooperative:hi")
      expect(pool_double).not_to have_received(:submit)
    end
  end

  describe "offloaded routing" do
    it "dispatches through OffloadPool#submit with non-blocking admission" do
      tool = make_tool(:offloaded)
      awaitable = described_class.call_async(
        tool: tool,
        args: {"x" => "work"},
        runtime: runtime_with_pool
      )

      expect(awaitable.wait_result).to eq("offloaded:work")
      expect(pool_double).to have_received(:submit)
        .with(cancellation_token: nil, on_full: :raise).once
    end

    it "accepts CPU-heavy synchronous work as ordinary :offloaded work" do
      tool_class = Class.new(Phronomy::Agent::Context::Capability::Base) do
        execution_mode :offloaded
        description "CPU-heavy synthetic tool"
        param :n, type: :integer, desc: "upper bound"

        def execute(n:)
          (1..n).sum
        end
      end

      awaitable = described_class.call_async(
        tool: tool_class.new,
        args: {"n" => 10_000},
        runtime: runtime_with_pool
      )
      expect(awaitable.wait_result).to eq(50_005_000)
    end
  end

  describe "cancellation_token propagation" do
    it "passes cancellation_token to pool.submit and Tool#call" do
      tool = make_tool(:offloaded)
      token = Phronomy::Concurrency::CancellationToken.new
      allow(tool).to receive(:call).and_call_original

      described_class.call_async(
        tool: tool,
        args: {"x" => "x"},
        cancellation_token: token,
        runtime: runtime_with_pool
      ).wait_result

      expect(pool_double).to have_received(:submit)
        .with(cancellation_token: token, on_full: :raise)
      expect(tool).to have_received(:call)
        .with({"x" => "x"}, cancellation_token: token)
    end
  end
end
