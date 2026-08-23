# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Tool#call_async compatibility" do
  ToolCallStub = Struct.new(:id, :name, :arguments)

  def build_ready_invocation(tool:, arguments:, config: {})
    invocation = Phronomy::Agent::ToolInvocation.new(
      execution_id: "execution-1",
      parent_agent_invocation_id: "parent-agent",
      agent: instance_double(Phronomy::Agent::Base),
      tool: tool,
      tool_call: ToolCallStub.new("call-1", tool.name, arguments),
      config: config
    )
    invocation.validate!
    invocation.send(
      :apply_authorization_outcome,
      Phronomy::Agent::ToolInvocation::AuthorizationOutcome.new(
        decision: :allow,
        facts: {},
        reason: nil
      )
    )
    invocation.mark_queued!
    invocation
  end

  it "keeps runtime out of the public Tool#call_async signature" do
    [
      Phronomy::Agent::Context::Capability::Base,
      Phronomy::Tools::Agent
    ].each do |tool_class|
      keyword_names = tool_class
        .instance_method(:call_async)
        .parameters
        .filter_map { |kind, name| name if %i[key keyreq].include?(kind) }

      expect(keyword_names).not_to include(:runtime)
    end
  end

  it "keeps Runtime injection and admission policy internal for the default call_async implementation" do
    tool_class = Class.new(Phronomy::Agent::Context::Capability::Base) do
      tool_name "offloaded_tool"
      description "Offloaded Tool"
      execution_mode :offloaded
      param :value, type: :string, desc: "Value"

      def execute(value:)
        value
      end
    end
    tool = tool_class.new
    invocation = build_ready_invocation(tool: tool, arguments: {"value" => "ok"})
    runtime = instance_double(Phronomy::Runtime)
    operation = Phronomy::Task.deferred(name: "offloaded-tool")
    operation.complete("ok")

    expect(Phronomy::Agent::ToolExecutor).to receive(:call_async).with(
      tool: tool,
      args: {value: "ok"},
      cancellation_token: nil,
      config: {},
      runtime: runtime,
      on_full: :raise
    ).and_return(operation)

    outcome = nil
    invocation.start_execution(runtime: runtime) { |value| outcome = value }

    expect(outcome.result).to eq("ok")
    expect(outcome.error).to be_nil
  end

  it "does not pass runtime to a Tool that overrides the public call_async protocol" do
    tool_class = Class.new(Phronomy::Agent::Context::Capability::Base) do
      tool_name "custom_async_tool"
      description "Custom async Tool"
      execution_mode :cooperative
      param :value, type: :string, desc: "Value"

      def execute(value:)
        value
      end

      def call_async(args, cancellation_token: nil, config: {})
        task = Phronomy::Task.deferred(name: "custom-async-tool")
        task.complete("#{args.fetch(:value)}:#{config.fetch(:suffix, "done")}")
        task
      end
    end
    tool = tool_class.new
    invocation = build_ready_invocation(
      tool: tool,
      arguments: {"value" => "ok"},
      config: {suffix: "custom"}
    )
    runtime = instance_double(Phronomy::Runtime)

    expect(Phronomy::Agent::ToolExecutor).not_to receive(:call_async)

    outcome = nil
    invocation.start_execution(runtime: runtime) { |value| outcome = value }

    expect(outcome.result).to eq("ok:custom")
    expect(outcome.error).to be_nil
  end
end
