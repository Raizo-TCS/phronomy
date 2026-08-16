# frozen_string_literal: true

require "securerandom"

RSpec.shared_examples "a Journal repository" do
  let(:journal_repository) { persistence.journals }
  let(:journal_agent_root) do
    Phronomy::Agent::AgentRoot.create(
      agent_id: "journal-agent-#{SecureRandom.uuid}",
      agent_definition_id: "contract-agent",
      definition_version: 1
    )
  end

  def build_contract_journal_record(agent_id:, record_id: SecureRandom.uuid, content_ref: nil)
    Phronomy::Agent::JournalRecord.new(
      agent_id: agent_id,
      record_id: record_id,
      kind: :knowledge,
      channel: :context,
      role: :user,
      content_ref: content_ref,
      context_candidate: true
    )
  end

  before do
    persistence.agents.create(journal_agent_root)
  end

  it "appends records at the expected position and assigns durable sequences" do
    first = build_contract_journal_record(agent_id: journal_agent_root.agent_id)
    second = build_contract_journal_record(agent_id: journal_agent_root.agent_id)

    appended = journal_repository.append(
      journal_agent_root.agent_id,
      expected_position: 0,
      records: [first, second]
    )

    expect(appended.map(&:sequence)).to eq([1, 2])
    expect(journal_repository.head(journal_agent_root.agent_id)).to eq(2)
  end

  it "rejects an unexpected append position" do
    record = build_contract_journal_record(agent_id: journal_agent_root.agent_id)

    expect do
      journal_repository.append(
        journal_agent_root.agent_id,
        expected_position: 1,
        records: [record]
      )
    end.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "rejects a duplicate record_id already present in the Journal" do
    record_id = SecureRandom.uuid
    first = build_contract_journal_record(
      agent_id: journal_agent_root.agent_id,
      record_id: record_id
    )
    duplicate = build_contract_journal_record(
      agent_id: journal_agent_root.agent_id,
      record_id: record_id
    )
    journal_repository.append(
      journal_agent_root.agent_id,
      expected_position: 0,
      records: [first]
    )

    expect do
      journal_repository.append(
        journal_agent_root.agent_id,
        expected_position: 1,
        records: [duplicate]
      )
    end.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "rejects duplicate record_ids within one append" do
    record_id = SecureRandom.uuid
    records = 2.times.map do
      build_contract_journal_record(
        agent_id: journal_agent_root.agent_id,
        record_id: record_id
      )
    end

    expect do
      journal_repository.append(
        journal_agent_root.agent_id,
        expected_position: 0,
        records: records
      )
    end.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "rejects records belonging to another Agent" do
    record = build_contract_journal_record(agent_id: "other-agent")

    expect do
      journal_repository.append(
        journal_agent_root.agent_id,
        expected_position: 0,
        records: [record]
      )
    end.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "reads records in sequence order and supports after/limit" do
    records = 3.times.map do
      build_contract_journal_record(agent_id: journal_agent_root.agent_id)
    end
    appended = journal_repository.append(
      journal_agent_root.agent_id,
      expected_position: 0,
      records: records
    )

    expect(journal_repository.read(journal_agent_root.agent_id).map(&:record_id))
      .to eq(appended.map(&:record_id))
    expect(journal_repository.read(journal_agent_root.agent_id, after: 1).map(&:sequence))
      .to eq([2, 3])
    expect(journal_repository.read(journal_agent_root.agent_id, limit: 2).map(&:sequence))
      .to eq([1, 2])
  end

  it "isolates durable Journal state from mutation of returned collections" do
    record = build_contract_journal_record(agent_id: journal_agent_root.agent_id)
    journal_repository.append(
      journal_agent_root.agent_id,
      expected_position: 0,
      records: [record]
    )
    loaded = journal_repository.read(journal_agent_root.agent_id)

    begin
      loaded.clear
    rescue FrozenError
      nil
    end

    expect(journal_repository.read(journal_agent_root.agent_id).length).to eq(1)
  end

  it "returns an empty Journal with head zero when no records exist" do
    expect(journal_repository.read(journal_agent_root.agent_id)).to eq([])
    expect(journal_repository.head(journal_agent_root.agent_id)).to eq(0)
  end

  it "deletes the Agent Journal" do
    journal_repository.append(
      journal_agent_root.agent_id,
      expected_position: 0,
      records: [build_contract_journal_record(agent_id: journal_agent_root.agent_id)]
    )
    journal_repository.delete(journal_agent_root.agent_id)

    expect(journal_repository.read(journal_agent_root.agent_id)).to eq([])
    expect(journal_repository.head(journal_agent_root.agent_id)).to eq(0)
  end
end
