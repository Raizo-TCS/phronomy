# frozen_string_literal: true

require "spec_helper"

RSpec.describe "ACS-11 EventLoop single-writer Agent runtime" do
  let(:root) { File.expand_path("../../..", __dir__) }

  def source(path)
    File.read(File.join(root, path))
  end

  it "removes the Activation shared-mutable runtime model from active source" do
    expect(File).not_to exist(File.join(root, "lib/phronomy/agent/agent_execution_activation.rb"))
    expect(File).not_to exist(File.join(root, "lib/phronomy/agent/activation_registry.rb"))

    active = Dir.glob(File.join(root, "lib/phronomy/**/*.rb")).map { |path| File.read(path) }.join("\n")
    expect(active).not_to include("AgentExecutionActivation")
    expect(active).not_to include("ActivationRegistry")
    expect(active).not_to include("__agent_activations")
    expect(active).not_to include("phronomy_activation")
  end

  it "keeps live Agent execution mutation on EventLoop and off worker result paths" do
    event_loop = source("lib/phronomy/engine/event_loop.rb")
    coordinator = source("lib/phronomy/agent/execution_coordinator.rb")

    expect(event_loop).to include("@agent_executions = {}")
    expect(event_loop).to include("def install_agent_execution")
    expect(event_loop).to include("def replace_agent_execution")
    expect(event_loop).to include("def release_agent_execution")
    expect(event_loop).to include("assert_event_loop_thread!")

    worker_sections = %w[
      perform_initial_preparation
      perform_provider_dispatch_preparation
      perform_tool_dispatch_preparation
      perform_resume_commit
      compute_terminal
      commit_suspended
      commit_completed
      commit_failed_outcome
    ].map do |method_name|
      coordinator.split("def #{method_name}", 2).fetch(1).split(/^      def /, 2).first
    end.join("\n")

    expect(worker_sections).not_to include("__replace_root")
    expect(worker_sections).not_to include("_append_journal_records")
    expect(worker_sections).not_to include("replace_agent_execution")
    expect(worker_sections).not_to include("acknowledge_runtime_snapshot")
  end

  it "keeps Task/listener delivery state outside the terminal worker command" do
    coordinator = source("lib/phronomy/agent/execution_coordinator.rb")
    command = coordinator
      .split("TerminalCommitCommand = Data.define", 2).fetch(1)
      .split("TerminalDelivery = Data.define", 2).first
    submit = coordinator
      .split("def submit_terminal_operation", 2).fetch(1)
      .split(/^      def /, 2).first

    expect(command).not_to include(":result_task")
    expect(command).not_to include(":application_listener")
    expect(command).not_to include(":approval_listener")
    expect(command).not_to include(":runtime_projection")
    expect(command).not_to include(":handoff_request")
    expect(submit).to include("compute_terminal(operation)")
    expect(submit).to include("delivery.result_task")
  end

  it "keeps live Handoff Agent references outside the terminal worker snapshot" do
    coordinator = source("lib/phronomy/agent/execution_coordinator.rb")
    multi = source("lib/phronomy/multi_agent/execution_coordinator.rb")
    terminal_view = coordinator
      .split("HandoffTerminalView = Data.define", 2).fetch(1)
      .split("TerminalView = Data.define", 2).first

    expect(terminal_view).to include(":target_agent_id")
    expect(terminal_view).not_to match(/:target_agent(?!_id)/)
    expect(multi).to include("request.target_agent_id")
    expect(multi).not_to match(/request\.handoff\.target_agent(?!_id)/)
  end

  it "does not start a follow-up durable operation after an application callback has already failed" do
    builder = source("lib/phronomy/agent/agent_invocation_session_builder.rb")
    method_source = builder
      .split("def self.prepare_and_start_llm_call", 2).fetch(1)
      .split("private_class_method :prepare_and_start_llm_call", 2).first

    expect(method_source.index("return if invocation.callback_failed?")).to be <
      method_source.index("prepare_provider_dispatch")
  end

  it "applies a known committed follow-up execution even if runtime materialization fails" do
    coordinator = source("lib/phronomy/agent/execution_coordinator.rb")
    worker = coordinator
      .split("def perform_provider_dispatch_preparation", 2).fetch(1)
      .split(/^      def /, 2).first
    apply = coordinator
      .split("def apply_confirmed_provider_dispatch_preparation_on_event_loop", 2).fetch(1)
      .split(/^      def /, 2).first

    expect(worker).to include("materialization_error")
    expect(worker).to include("execution: updated")
    expect(worker).to include("error: materialization_error")
    expect(apply.index("execution: result.execution")).to be <
      apply.index("if result.error")
    expect(apply.index("acknowledge_runtime_snapshot")).to be <
      apply.index("if result.error")
  end

  it "does not expose live mutable execution state through Runtime owner lookup" do
    runtime = source("lib/phronomy/engine/runtime.rb")
    event_loop = source("lib/phronomy/engine/event_loop.rb")

    expect(runtime).to include("def __agent_execution_owner")
    expect(runtime).not_to include("def __agent_activations")
    expect(event_loop).to include("AgentExecutionOwner = Data.define")
    expect(event_loop).not_to match(/AgentExecutionOwner = Data\.define\([^\n]*:invocation/)
    expect(event_loop).not_to match(/AgentExecutionOwner = Data\.define\([^\n]*:execution,/)
  end

  it "rejects a stale Provider result by semantic llm_call_id without advancing the invocation" do
    agent = Object.new
    invocation = Phronomy::Agent::AgentInvocation.new(
      agent: agent,
      input: "hello",
      config: {execution_id: "execution-1"},
      execution_id: "execution-1"
    )
    projection = Struct.new(:manifest_ref).new("sha256:manifest-current")
    invocation.begin_llm_call!(projection, llm_call_id: "llm-current")

    stale = Phronomy::Agent::LLMOperationResult.new(
      llm_call_id: "llm-stale",
      error: Phronomy::Error.new("stale"),
      streaming: false
    )
    event = Phronomy::Event.new(
      type: :llm_failed,
      target_id: "session-current",
      payload: stale
    )

    expect(invocation.handle_fsm_event(event)).to eq(:consume)
    expect(invocation.current_llm_call_id).to eq("llm-current")
    expect(invocation.runtime_snapshot.fetch(:llm_results)).to be_empty
  end

  it "applies the current Provider result and records its provenance for the durable barrier" do
    invocation = Phronomy::Agent::AgentInvocation.new(
      agent: Object.new,
      input: "hello",
      config: {execution_id: "execution-1"},
      execution_id: "execution-1"
    )
    projection = Struct.new(:manifest_ref).new("sha256:manifest-current")
    invocation.begin_llm_call!(projection, llm_call_id: "llm-current")
    error = Phronomy::Error.new("provider failed")
    current = Phronomy::Agent::LLMOperationResult.new(
      llm_call_id: "llm-current",
      error: error,
      streaming: false
    )
    event = Phronomy::Event.new(
      type: :llm_failed,
      target_id: "session-current",
      payload: current
    )

    expect(invocation.handle_fsm_event(event)).to eq(true)
    expect(invocation.current_llm_call_id).to be_nil
    item = invocation.runtime_snapshot.fetch(:llm_results).fetch(0)
    expect(item.fetch(:llm_call_id)).to eq("llm-current")
    expect(item.fetch(:manifest_ref)).to eq("sha256:manifest-current")
    expect(item.fetch(:error)).to be(error)
  end

  it "rejects a stale Tool result by semantic tool_invocation_id without advancing ToolInvocation" do
    tool_call = Struct.new(:id, :name, :arguments).new("call-1", "missing", {})
    invocation = Phronomy::Agent::ToolInvocation.new(
      execution_id: "execution-1",
      agent: Object.new,
      tool: nil,
      tool_call: tool_call,
      config: {},
      id: "tool-current"
    )
    stale = Phronomy::Agent::ToolInvocation::ExecutionOutcome.new(
      tool_invocation_id: "tool-stale",
      result: "late"
    )
    event = Phronomy::Event.new(
      type: :execution_completed,
      target_id: "tool-session-current",
      payload: stale
    )

    expect(invocation.handle_fsm_event(event)).to eq(:consume)
    expect(invocation.status).to eq(:created)
    expect(invocation.result).to be_nil
  end

  it "does not share mutable runtime-event payload containers with application listeners" do
    delivered = nil
    invocation = Phronomy::Agent::AgentInvocation.new(
      agent: Object.new,
      input: "hello",
      config: {execution_id: "execution-1"},
      execution_id: "execution-1",
      event_listener: ->(event) { delivered = event }
    )
    payload = {nested: {value: +"original"}}
    invocation.send(
      :deliver_event,
      Phronomy::Agent::StreamEvent.new(type: :diagnostic, payload: payload)
    )

    delivered.payload[:nested][:value].replace("changed")

    recorded = invocation.runtime_snapshot.fetch(:runtime_events).fetch(0)
    expect(recorded.payload[:nested][:value]).to eq("original")
  end

  it "acknowledges only the runtime facts captured by one durable operation snapshot" do
    invocation = Phronomy::Agent::AgentInvocation.new(
      agent: Object.new,
      input: "hello",
      config: {execution_id: "execution-1"},
      execution_id: "execution-1"
    )
    first = Phronomy::Agent::StreamEvent.new(type: :diagnostic_a, payload: {value: "A"})
    later = Phronomy::Agent::StreamEvent.new(type: :diagnostic_b, payload: {value: "B"})

    invocation.send(:deliver_event, first)
    snapshot = invocation.runtime_snapshot
    invocation.send(:deliver_event, later)
    invocation.acknowledge_runtime_snapshot(snapshot)

    expect(invocation.runtime_snapshot.fetch(:runtime_events)).to eq([later])
  end
end
