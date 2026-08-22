# frozen_string_literal: true

require "securerandom"

RSpec.shared_examples "an Agent repository" do
  let(:agent_repository) { persistence.agents }
  let(:agent_root) do
    Phronomy::Agent::AgentRoot.create(
      agent_id: "contract-agent-#{SecureRandom.uuid}",
      agent_definition_id: "contract-agent",
      agent_definition_version: 1
    )
  end

  it "creates and loads an AgentRoot" do
    expect(agent_repository.create(agent_root).to_h).to eq(agent_root.to_h)
    expect(agent_repository.load(agent_root.agent_id).to_h).to eq(agent_root.to_h)
  end

  it "rejects duplicate create" do
    agent_repository.create(agent_root)

    expect do
      agent_repository.create(agent_root)
    end.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "raises NotFoundError for a missing Agent" do
    expect do
      agent_repository.load("missing-#{SecureRandom.uuid}")
    end.to raise_error(Phronomy::Persistence::NotFoundError)
  end

  it "saves only at the expected revision" do
    agent_repository.create(agent_root)
    updated = agent_root.with(agent_revision: agent_root.agent_revision + 1)

    expect(
      agent_repository.save(
        agent_root.agent_id,
        expected_revision: agent_root.agent_revision,
        root: updated
      ).to_h
    ).to eq(updated.to_h)

    expect(agent_repository.load(agent_root.agent_id).agent_revision).to eq(1)
  end

  it "rejects a stale expected revision" do
    agent_repository.create(agent_root)
    first = agent_root.with(agent_revision: 1)
    agent_repository.save(agent_root.agent_id, expected_revision: 0, root: first)
    stale = agent_root.with(agent_revision: 1)

    expect do
      agent_repository.save(agent_root.agent_id, expected_revision: 0, root: stale)
    end.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "rejects an Agent identity mismatch" do
    agent_repository.create(agent_root)
    other = Phronomy::Agent::AgentRoot.create(
      agent_id: "other-#{SecureRandom.uuid}",
      agent_definition_id: "contract-agent",
      agent_definition_version: 1
    ).with(agent_revision: 1)

    expect do
      agent_repository.save(
        agent_root.agent_id,
        expected_revision: 0,
        root: other
      )
    end.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "requires revision to advance exactly once" do
    agent_repository.create(agent_root)
    skipped = agent_root.with(agent_revision: 2)

    expect do
      agent_repository.save(
        agent_root.agent_id,
        expected_revision: 0,
        root: skipped
      )
    end.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "deletes idempotently" do
    agent_repository.create(agent_root)
    agent_repository.delete(agent_root.agent_id)
    expect { agent_repository.delete(agent_root.agent_id) }.not_to raise_error

    expect do
      agent_repository.load(agent_root.agent_id)
    end.to raise_error(Phronomy::Persistence::NotFoundError)
  end
end
