# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Tools::Agent, "default composition" do
  let(:definition) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "tool-composition", version: 1
    end
  end

  def tool_for(definition)
    described_class.from_agent(definition).new
  end

  it "does not acquire persistence when defining or constructing a Tool" do
    expect(Phronomy::Agent::DefaultPersistence).not_to receive(:build)
    expect(Phronomy::PersistenceComposition).not_to receive(:agent)
    tool_for(definition)
  end

  it "uses the supplied fresh store for each synchronous call without the run_once facade" do
    stores = [Object.new, Object.new]
    token = Phronomy::Concurrency::CancellationToken.new
    first = double("first agent")
    second = double("second agent")
    expect(Phronomy::Agent).not_to receive(:run_once)
    expect(Phronomy::Agent::DefaultPersistence).to receive(:build).ordered.and_return(stores[0])
    expect(definition).to receive(:create).with(persistence: stores[0]).ordered.and_return(first)
    expect(first).to receive(:invoke_async).with("first", config: {cancellation_token: token}).ordered.and_return(Phronomy::TaskResult.completed({output: 42}))
    expect(first).to receive(:unload_async).ordered.and_return(Phronomy::TaskResult.completed(true))
    expect(Phronomy::Agent::DefaultPersistence).to receive(:build).ordered.and_return(stores[1])
    expect(definition).to receive(:create).with(persistence: stores[1]).ordered.and_return(second)
    expect(second).to receive(:invoke_async).with("second", config: {}).ordered.and_return(Phronomy::TaskResult.completed({output: nil}))
    expect(second).to receive(:unload_async).ordered.and_return(Phronomy::TaskResult.completed(true))

    tool = tool_for(definition)
    expect(tool.execute(input: "first", cancellation_token: token)).to eq("42")
    expect(tool.execute(input: "second")).to eq("")
  end

  it "retains the asynchronous factory path and explicit config token priority" do
    store = Object.new
    agent = double("async agent")
    explicit = Phronomy::Concurrency::CancellationToken.new
    fallback = Phronomy::Concurrency::CancellationToken.new
    config = {cancellation_token: explicit}.freeze
    task = Phronomy::TaskResult.deferred(name: "tool-composition")
    expect(Phronomy::Agent).not_to receive(:run_once)
    expect(Phronomy::Agent::DefaultPersistence).to receive(:build).and_return(store)
    expect(definition).to receive(:create).with(persistence: store).and_return(agent)
    expect(agent).to receive(:invoke_async).with("async", config: {cancellation_token: explicit}).and_return(task)
    expect(agent).to receive(:unload_async).and_return(Phronomy::TaskResult.completed(true))

    result = tool_for(definition).call_async({"input" => "async"}, cancellation_token: fallback, config: config)
    task.complete({output: 21})
    expect(result.wait_result).to eq("21")
    expect(config).to eq(cancellation_token: explicit)
  end

  it "keeps fresh per-call Agents and stores even when an application store is configured" do
    configured = Phronomy::PersistenceComposition.agent
    Phronomy.configure { |c| c.agent_store = configured }
    seen = []
    definition.define_method(:invoke) do |_input, **_options|
      seen << [self, persistence]
      {output: "ok"}
    end
    definition.define_method(:invoke_async) do |input, **options|
      Phronomy::TaskResult.deferred(name: "fresh-agent").tap { |task| task.complete(invoke(input, **options)) }
    end
    tool = tool_for(definition)
    expect(tool.execute(input: "one")).to eq("ok")
    expect(tool.execute(input: "two")).to eq("ok")
    expect(tool.call_async({"input" => "three"}).wait_result).to eq("ok")
    expect(seen.map { |agent, _| agent.object_id }.uniq.size).to eq(3)
    expect(seen.map { |_, store| store.object_id }.uniq.size).to eq(3)
    expect(seen.map(&:last)).not_to include(configured)
    expect(seen.all? { |agent, _| definition.get(agent.agent_id).nil? }).to be(true)
  ensure
    Phronomy.reset_configuration!
  end

  it "preserves a synchronous Agent failure without retrying or wrapping it in execute" do
    error = Phronomy::ExecutionRehydrationRequiredError.new("recover")
    agent = double("agent")
    allow(definition).to receive(:create).and_return(agent)
    expect(agent).to receive(:invoke_async).once.and_raise(error)
    expect(agent).to receive(:unload_async).and_return(Phronomy::TaskResult.completed(true))
    expect { tool_for(definition).execute(input: "input") }.to raise_error { |raised| expect(raised).to equal(error) }
  end

  it "preserves a store factory failure without creating an Agent" do
    error = RuntimeError.new("store unavailable")
    expect(Phronomy::Agent::DefaultPersistence).to receive(:build).and_raise(error)
    expect(definition).not_to receive(:create)
    expect { tool_for(definition).execute(input: "input") }.to raise_error { |raised| expect(raised).to equal(error) }
  end
end
