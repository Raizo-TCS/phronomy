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
    stores = Array.new(2) { Phronomy::PersistenceComposition.agent }
    token = Phronomy::Concurrency::CancellationToken.new
    seen = []
    definition.define_method(:invoke_async) do |input, config:|
      seen << [self, persistence, input, config]
      Phronomy::TaskResult.completed({output: (input == "first") ? 42 : nil})
    end
    expect(Phronomy::Agent).not_to receive(:run_once)
    expect(Phronomy::Agent::DefaultPersistence).to receive(:build).ordered.and_return(stores[0])
    expect(definition).to receive(:create).with(persistence: stores[0]).ordered.and_call_original
    expect(Phronomy::Agent::DefaultPersistence).to receive(:build).ordered.and_return(stores[1])
    expect(definition).to receive(:create).with(persistence: stores[1]).ordered.and_call_original

    tool = tool_for(definition)
    expect(tool.execute(input: "first", cancellation_token: token)).to eq("42")
    expect(tool.execute(input: "second")).to eq("")
    expect(seen.map { |_, store, input, config| [store, input, config] }).to eq([
      [stores[0], "first", {cancellation_token: token}],
      [stores[1], "second", {}]
    ])
    expect(seen.map(&:first).uniq.size).to eq(2)
    expect(seen.all? { |agent, _| definition.get(agent.agent_id).nil? }).to be(true)
  end

  it "retains the asynchronous factory path and explicit config token priority" do
    store = Phronomy::PersistenceComposition.agent
    explicit = Phronomy::Concurrency::CancellationToken.new
    fallback = Phronomy::Concurrency::CancellationToken.new
    config = {cancellation_token: explicit}.freeze
    task = Phronomy::TaskResult.deferred(name: "tool-composition")
    seen = []
    definition.define_method(:invoke_async) do |input, config:|
      seen << [self, input, config]
      task
    end
    expect(Phronomy::Agent).not_to receive(:run_once)
    expect(Phronomy::Agent::DefaultPersistence).to receive(:build).and_return(store)
    expect(definition).to receive(:create).with(persistence: store).and_call_original

    result = tool_for(definition).call_async({"input" => "async"}, cancellation_token: fallback, config: config)
    expect(result).not_to be_done
    task.complete({output: 21})
    expect(result.wait_result).to eq("21")
    expect(config).to eq(cancellation_token: explicit)
    expect(seen.length).to eq(1)
    agent, input, invocation_config = seen.first
    expect(input).to eq("async")
    expect(invocation_config).to eq(cancellation_token: explicit)
    expect(agent.persistence).to equal(store)
    expect(definition.get(agent.agent_id)).to be_nil
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
    seen = []
    definition.define_method(:invoke_async) do |input, config:|
      seen << self
      raise error
    end
    expect { tool_for(definition).execute(input: "input") }.to raise_error { |raised| expect(raised).to equal(error) }
    expect(seen.length).to eq(1)
    expect(definition.get(seen.first.agent_id)).to be_nil
  end

  it "preserves a store factory failure without creating an Agent" do
    error = RuntimeError.new("store unavailable")
    expect(Phronomy::Agent::DefaultPersistence).to receive(:build).and_raise(error)
    expect(definition).not_to receive(:create)
    expect { tool_for(definition).execute(input: "input") }.to raise_error { |raised| expect(raised).to equal(error) }
  end
end
