# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe "CG-02 generic invocation identity removal" do
  let(:root) { File.expand_path("../..", __dir__) }

  it "removes generic InvocationContext identities without replacements" do
    methods = Phronomy::InvocationContext.public_instance_methods(false)

    expect(methods).not_to include(:thread_id, :session_id)
    expect(methods).not_to include(
      :correlation_id,
      :conversation_id,
      :application_session_id
    )

    keys = Phronomy::InvocationContext
      .instance_method(:initialize)
      .parameters
      .map(&:last)
    expect(keys).not_to include(:thread_id, :session_id)
    expect(keys).to include(:task_id, :parent_task_id, :user_id)
  end

  it "removes thread_id from all four Agent invocation APIs" do
    %i[invoke invoke_async stream stream_async].each do |method_name|
      keys = Phronomy::Agent::Base
        .instance_method(method_name)
        .parameters
        .map(&:last)
      expect(keys).not_to include(:thread_id)
    end
  end

  it "rejects legacy generic identity through Agent config" do
    agent_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "cg02a-config-rejection", version: 1
    end
    agent = agent_class.new

    expect {
      agent.invoke_async("hello", config: {thread_id: "legacy"})
    }.to raise_error(ArgumentError, /thread_id.*removed/)

    expect {
      agent.invoke_async("hello", config: {session_id: "legacy"})
    }.to raise_error(ArgumentError, /session_id.*removed/)
  end

  it "keeps task IDs as tracing-only purpose-specific identifiers" do
    ctx = Phronomy::InvocationContext.new(
      task_id: "child",
      parent_task_id: "parent"
    )
    expect(ctx.task_id).to eq("child")
    expect(ctx.parent_task_id).to eq("parent")
  end

  it "removes AgentInvocation generic thread_id but keeps Runtime bridge" do
    methods = Phronomy::Agent::AgentInvocation.public_instance_methods(false)
    expect(methods).not_to include(:thread_id)

    expect(methods).to include(:session_id)
    expect(
      Phronomy::Agent::AgentInvocation
        .instance_method(:set_graph_metadata)
        .parameters
    ).to include([:key, :thread_id])
  end

  it "removes generic identity from MultiAgent public/child contracts" do
    %i[fan_out fan_out_async subagent].each do |method_name|
      keys = Phronomy::MultiAgent::Orchestrator
        .instance_method(method_name)
        .parameters
        .map(&:last)
      expect(keys).not_to include(:thread_id)
    end

    expect(Phronomy::MultiAgent::FanOutInvocation::Child.members)
      .not_to include(:thread_id)
  end

  it "does not put generic thread_id into finalized Agent model config" do
    source = File.read(
      File.join(root, "lib/phronomy/agent/context_assembler.rb")
    )
    expect(source).not_to include(
      '"thread_id" => config[:thread_id]'
    )
  end

  it "stops writing generic thread_id/correlation into new Agent execution" do
    source = File.read(
      File.join(root, "lib/phronomy/agent/execution_coordinator.rb")
    )
    expect(source).not_to include('"thread_id" => thread_id')
    expect(source).not_to include("correlation_id:")
  end

  it "does not propagate legacy duck-typed generic IDs into approval context" do
    legacy_like_context = Struct.new(
      :thread_id,
      :session_id,
      :user_id,
      :token_budget,
      :task_id,
      :parent_task_id
    ).new(
      thread_id: "legacy-thread",
      session_id: "legacy-session",
      user_id: "user-1",
      token_budget: 128,
      task_id: "task-1",
      parent_task_id: "task-0"
    )

    invocation = Phronomy::Agent::AgentInvocation.new(
      agent: Object.new,
      input: "hello",
      config: {invocation_context: legacy_like_context}
    )

    expect(invocation.approval_context).to eq(
      user_id: "user-1",
      token_budget: 128,
      task_id: "task-1",
      parent_task_id: "task-0"
    )
  end

  it "rejects removed generic identity on approval resume config" do
    agent_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "cg02a-approval-config-rejection", version: 1
    end
    agent = agent_class.new

    expect {
      agent.approve_async(
        "missing-execution",
        approval_request_id: "request-1",
        config: {thread_id: "legacy"}
      )
    }.to raise_error(ArgumentError, /thread_id.*removed/)

    expect {
      agent.approve_async(
        "missing-execution",
        approval_request_id: "request-1",
        config: {session_id: "legacy"}
      )
    }.to raise_error(ArgumentError, /session_id.*removed/)
  end

  it "snapshots InvocationContext as a compatibility surface without generic IDs" do
    snapshot = JSON.parse(
      File.read(File.join(root, "spec/fixtures/api_snapshot.json"))
    )
    entry = snapshot.find { |item|
      item["name"] == "Phronomy::InvocationContext"
    }

    expect(entry).not_to be_nil
    methods = entry.fetch("public_instance_methods")
    expect(methods).to include("task_id", "parent_task_id", "user_id")
    expect(methods).not_to include("thread_id", "session_id")
  end

  it "removes generic correlation from the canonical Journal model" do
    expect(Phronomy::Agent::JournalRecord::ATTRIBUTES)
      .not_to include(:correlation_id)
  end
end
