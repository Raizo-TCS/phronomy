# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Subagent Tool contract" do
  let(:source) { Phronomy::Concurrency::PhysicalCompletionTask.deferred(name: "child") }
  let(:child_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "unit12-child", version: 1
    end
  end
  let(:parent_class) do
    child = child_class
    Class.new(Phronomy::MultiAgent::Orchestrator) do
      agent_definition id: "unit12-parent", version: 1
      subagent :worker, child
    end
  end
  let(:tool_class) { parent_class._subagent_tool_classes.fetch(0) }
  let(:tool) { tool_class.new }

  before do
    allow_any_instance_of(child_class).to receive(:invoke_async).and_return(source)
  end

  it "defines and executes delegation without loading the concrete Agent Tool" do
    hide_const("Phronomy::Tools::Agent")
    expect(tool_class.superclass).to eq(Phronomy::Tool::Base)
    expect(tool_class.execution_mode).to eq(:cooperative)
    expect(tool.parameters_schema).to include("required" => ["input"])
    expect(Phronomy::Tool::ToolExecutor).not_to receive(:call_async)
    result = tool.call_async({input: "work"})
    expect(result).not_to be_done
    source.complete(output: "done")
    expect(result.wait_result).to eq("done")
    expect(result.physical_complete?).to be(false)
    source.mark_physical_complete!
    expect(result.physical_complete?).to be(true)
  end

  it "preserves the Tool schema policy for ordinary calls" do
    expect(tool.call_async({}).wait_result).to include("Schema validation failed")
    tool_class.on_schema_error :raise
    expect { tool.call_async({}).wait_result }.to raise_error(Phronomy::ToolError, /schema error/)
  end

  it "preserves rehydration requirements as Agent outcomes under Tool suppression" do
    tool_class.on_error :suppress
    error = Phronomy::ExecutionRehydrationRequiredError.new("resolve child")
    result = tool.call_async({input: "work"})
    source.fail(error)
    expect { result.wait_result }.to raise_error { |actual| expect(actual).to equal(error) }
  end

  it "does not start an ordinary child after cancellation" do
    token = Phronomy::Concurrency::CancellationToken.new.cancel!
    expect(child_class).not_to receive(:new)
    expect { tool.call_async({input: "work"}, cancellation_token: token).wait_result }
      .to raise_error(Phronomy::CancellationError)
  end

  it "still reconciles an admitted durable child after cancellation" do
    token = Phronomy::Concurrency::CancellationToken.new.cancel!
    parent = Object.new
    tool._orchestrator_context = {parent: parent}
    config = {phronomy_tool_invocation_id: "slot", execution_id: "parent-execution"}
    coordinator = Phronomy::MultiAgent.const_get(:DurableSubagentCoordinator, false)
    expect(coordinator).to receive(:start).with(parent: parent,
      tool_invocation_id: "slot", parent_execution_id: "parent-execution",
      config: config.merge(cancellation_token: token)).and_return(source)
    expect(child_class).not_to receive(:new)

    expect(tool.call_async({input: "work"}, cancellation_token: token, config: config)).to equal(source)
  end

  it "retains repeated configured transformations after ordinary output truncation" do
    tool_class.max_result_size 3
    transform = ->(value, _name, _args) { "#{value}|pass" }
    prepared = Phronomy::Tool::Operation.with_result_transform(tool_class, &transform)
    prepared = Phronomy::Tool::Operation.with_result_transform(prepared, &transform)
    result = prepared.new.call_async({input: "work"})
    source.complete(output: "abcdef")
    expect(result.wait_result).to eq("abc...[truncated]|pass|pass")
  end
end
