# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent-as-Tool blocking-pool independence" do
  it "does not consume the only blocking worker while waiting for a child Agent" do
    pool = Phronomy::Concurrency::OffloadPool.new(
      pool_size: 1,
      queue_size: 4,
      name: :agent_tool_starvation
    )
    runtime_double = instance_double(Phronomy::Runtime, offload: pool)
    allow(Phronomy::Runtime).to receive(:instance).and_return(runtime_double)
    allow(runtime_double).to receive(:__create_agent).and_yield(runtime_double)

    launch_thread_names = []
    child_agent = Class.new do
      define_method(:invoke_async) do |input, **_options|
        launch_thread_names << Thread.current.name

        result_task = Phronomy::Task.deferred(name: "child-agent")
        operation = pool.submit(on_full: :raise) do
          {output: "child:#{input}"}
        end
        operation.on_complete do |value, error|
          error ? result_task.fail(error) : result_task.complete(value)
        end
        result_task
      end
    end

    orchestrator_class = Class.new(Phronomy::MultiAgent::Orchestrator) do
      agent_definition id: "orchestrator", version: 1
      subagent :worker, child_agent, inherit_knowledge: false
    end
    orchestrator = orchestrator_class.new
    original_tool_class = orchestrator_class.tools.first
    prepared_tool_class = orchestrator.send(:prepare_tool_class, original_tool_class)
    tool = prepared_tool_class.new

    expect(prepared_tool_class.execution_mode).to eq(:cooperative)

    result = tool.call_async({"input" => "x"}).wait_result(timeout: 2)

    expect(result).to eq("child:x")
    expect(launch_thread_names.length).to eq(1)
    expect(launch_thread_names.first.to_s).not_to start_with("phronomy-blocking-pool")
    expect(pool.active_count).to eq(0)
  ensure
    pool&.shutdown(drain_timeout: 2)
  end
end
