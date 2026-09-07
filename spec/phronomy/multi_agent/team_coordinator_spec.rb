# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::MultiAgent::TeamCoordinator do
  let(:store) { Phronomy::Persistence::InMemory.new }
  let(:worker) do
    Class.new(Phronomy::Agent::Base) { agent_definition id: "team-unit-worker", version: 1 }
  end
  let(:definition) do
    child = worker
    Class.new(described_class) do
      team_definition id: "team-unit", version: 1
      coordinator_model "model"
      coordinator_instructions "plan"
      coordinator_provider :openai
      pool size: 2, agent: child, on_error: :skip
    end
  end

  it "requires stable definition lineage at construction" do
    expect { Class.new(described_class).new(persistence: store) }.to raise_error(Phronomy::ConfigurationError, /team_definition/)
  end

  it "retains the configured coordinator, worker and pure calculation callbacks" do
    scheduler = ->(workers) { workers.first }
    aggregator = ->(assignments) { assignments.length }
    definition.schedule(&scheduler)
    definition.aggregate(&aggregator)
    expect(definition._coordinator_model).to eq("model")
    expect(definition._coordinator_instructions).to eq("plan")
    expect(definition._coordinator_provider).to eq(:openai)
    expect(definition._worker_agent).to eq(worker)
    expect(definition._pool_size).to eq(2)
    expect(definition._on_error).to eq(:skip)
    expect(definition._scheduler).to equal(scheduler)
    expect(definition._aggregator).to equal(aggregator)
  end

  it "rejects invalid pool admission settings" do
    expect { definition.pool(size: 0, agent: worker) }.to raise_error(ArgumentError)
    expect { definition.pool(size: 1, agent: Object) }.to raise_error(ArgumentError)
    expect { definition.pool(size: 1, agent: worker, on_error: :ignore) }.to raise_error(ArgumentError)
  end

  it "keeps one live owner for a Team identity" do
    team = definition.create(team_id: "owned", persistence: store)
    expect(definition.get("owned")).to equal(team)
    expect(definition.load("owned", persistence: store)).to equal(team)
    expect { definition.new(team_id: "owned", persistence: store) }.to raise_error(Phronomy::Persistence::ConflictError)
    expect { definition.load("owned", persistence: Phronomy::Persistence::InMemory.new) }.to raise_error(Phronomy::ConfigurationError)
  end

  it "does not rebind a live Team listener" do
    definition.create(team_id: "listener", persistence: store, on_event: ->(_event) {})
    expect { definition.load("listener", persistence: store, on_event: ->(_event) {}) }.to raise_error(Phronomy::ConfigurationError, /rebound/)
  end

  it "loads only an existing durable Team" do
    expect { definition.load("missing", persistence: store) }.to raise_error(Phronomy::Persistence::NotFoundError)
  end

  it "rejects a stale Team incarnation after Runtime shutdown" do
    team = definition.create(persistence: store)
    Phronomy.reset_runtime!
    expect { team.invoke("work") }.to raise_error(Phronomy::RuntimeShutdownError)
    expect(definition.get(team.team_id)).to be_nil
    expect(definition.load(team.team_id, persistence: store)).not_to equal(team)
  end

  it "uses TeamExecution admission across different live wrappers" do
    team = definition.create(persistence: store)
    run = team.send(:admit, "one")
    expect { team.invoke("two") }.to raise_error(Phronomy::AgentBusyError, /resume/)
    expect(team.executions.map(&:team_execution_id)).to eq([run.team_execution_id])
  end

  it "does not cancel an unrelated Team run" do
    team = definition.create(persistence: store)
    other = definition.create(persistence: store)
    run = other.send(:admit, "one")
    expect { team.cancel(run.team_execution_id) }.to raise_error(Phronomy::Persistence::ConflictError)
    expect(other.executions.first.metadata["cancel_requested"]).to be(false)
  end
end
