# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Tool child execution environment" do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "tool-child-environment", version: 1
    end
  end
  let(:tool_class) do
    Class.new(Phronomy::Tool::Base) do
      tool_name "environment-tool"
      execution_mode :offloaded
      param :value, type: :string
      def execute(value:) = value
    end
  end
  let(:invocation) do
    Phronomy::Agent::ToolInvocation.new(
      execution_id: "execution-1", agent: agent_class.new, tool: tool_class.new,
      tool_call: Phronomy::Tool::CallRequest.new(id: "call-1", name: "environment-tool", arguments: {value: "ok"}),
      config: {authorization_timeout: 3}
    ).tap(&:validate!)
  end
  let(:registry) { double("owning registry", supervise_agent_operation: nil) }
  let(:environment) { instance_double(Phronomy::Agent::ExecutionEnvironment, registry: registry) }

  it "submits authorization to the supplied environment and applies its result only on delivery" do
    child = invocation
    operation = Phronomy::TaskResult.deferred
    work = nil
    expect(environment).to receive(:submit).with(
      pool_name: :authorization,
      size: Phronomy.configuration.authorization_pool_size,
      queue_size: Phronomy.configuration.authorization_queue_size,
      timeout: 3, cancellation_token: nil, on_full: :raise
    ) { |&block|
      work = block
      operation
    }
    expect(registry).to receive(:supervise_agent_operation).with("execution-1", operation)
    expect(Phronomy::Runtime).not_to receive(:instance)
    expect(Phronomy::Agent::ExecutionEnvironment).not_to receive(:current)
    outcome = nil
    child.start_authorization(environment: environment) { |value| outcome = value }
    Thread.new { operation.complete(work.call) }.join
    expect(child.status).to eq(:valid)
    expect(outcome.decision).to eq(:allow)
    expect(child.handle_fsm_event(Phronomy::Event.new(type: :authorization_completed, target_id: "session", payload: outcome))).to be(true)
    expect(child).to be_authorized
  end

  it "submits Tool work to the same environment without applying a worker result to live state" do
    child = invocation
    child.restore_state!(status: :authorized)
    child.mark_queued!
    operation = Phronomy::TaskResult.deferred
    work = nil
    expect(environment).to receive(:submit).with(cancellation_token: nil, on_full: :raise) { |&block|
      work = block
      operation
    }
    expect(registry).to receive(:supervise_agent_operation).with("execution-1", operation)
    expect(Phronomy::Runtime).not_to receive(:instance)
    expect(Phronomy::Agent::ExecutionEnvironment).not_to receive(:current)
    outcome = nil
    child.start_execution(environment: environment) { |value| outcome = value }
    child.mark_running!
    Thread.new { operation.complete(work.call) }.join
    expect(child.status).to eq(:running)
    expect(child.result).to be_nil
    expect(outcome.result).to eq("ok")
    child.handle_fsm_event(Phronomy::Event.new(type: :execution_completed, target_id: "session", payload: outcome))
    expect(child).to be_execution_completed
    expect(child.result).to eq("ok")
  end

  it "routes rebuilt child sessions through the original environment with fresh session identities" do
    child = invocation
    original_loop = double("original loop")
    original = Phronomy::Agent::EngineEnvironment.new(runtime: double("original runtime", event_loop: original_loop))
    parent_sink = double("current parent sink")
    other = double("other environment")
    Phronomy::Agent::ExecutionEnvironment.install_provider(-> { other })
    expect(other).not_to receive(:build_tool_session)
    expect(Phronomy::Runtime).not_to receive(:instance)
    first = original.build_tool_session(invocation: child, parent_sink: parent_sink)
    resumed = original.build_tool_session(invocation: child, parent_sink: parent_sink,
      resume_event: :dispatch, resume_phase: :authorized)
    expect(first.id).not_to eq(resumed.id)
    expect(first.context).to be(child)
    expect(resumed.context).to be(child)
    expect(resumed.instance_variable_get(:@event_loop)).to be(original_loop)
    expect(resumed.id).not_to eq(child.id)
    expect(child.tool_call_id).to eq("call-1")
    expect(child.execution_id).to eq("execution-1")
  ensure
    Phronomy::Agent::ExecutionEnvironment.install_provider(-> { Phronomy::Agent::EngineEnvironment.new })
  end
end
