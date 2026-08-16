# frozen_string_literal: true

require "securerandom"

RSpec.shared_examples "a workflow state repository" do
  let(:repository) { persistence.workflow_states }

  def workflow_contract_value(hash, key)
    hash.key?(key) ? hash[key] : hash[key.to_s]
  end

  def workflow_contract_snapshot(record)
    workflow_contract_value(record, :snapshot)
  end

  def workflow_contract_revision(record)
    workflow_contract_value(record, :revision)
  end

  it "returns nil for an unknown thread_id" do
    expect(repository.load("missing-#{SecureRandom.uuid}")).to be_nil
  end

  it "uses optimistic revisions for save" do
    thread_id = "t1-#{SecureRandom.uuid}"
    expect(
      repository.save(
        thread_id,
        expected_revision: nil,
        snapshot: {fields: {value: 1}, phase: "pause"}
      )
    ).to eq(1)

    expect(
      repository.save(
        thread_id,
        expected_revision: 1,
        snapshot: {fields: {value: 2}, phase: "__end__"}
      )
    ).to eq(2)
  end

  it "rejects a stale expected_revision" do
    thread_id = "t1-#{SecureRandom.uuid}"
    repository.save(
      thread_id,
      expected_revision: nil,
      snapshot: {fields: {value: 1}, phase: "pause"}
    )

    expect do
      repository.save(
        thread_id,
        expected_revision: nil,
        snapshot: {fields: {value: 2}, phase: "__end__"}
      )
    end.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "returns a snapshot representation accepted by WorkflowRunner" do
    thread_id = "t1-#{SecureRandom.uuid}"
    repository.save(
      thread_id,
      expected_revision: nil,
      snapshot: {fields: {value: 1}, phase: "pause"}
    )

    record = repository.load(thread_id)
    snapshot = workflow_contract_snapshot(record)
    fields = workflow_contract_value(snapshot, :fields)

    expect(workflow_contract_revision(record)).to eq(1)
    expect(workflow_contract_value(fields, :value)).to eq(1)
    expect(workflow_contract_value(snapshot, :phase)).to eq("pause")
  end

  it "isolates stored snapshots from caller mutation" do
    thread_id = "t1-#{SecureRandom.uuid}"
    repository.save(
      thread_id,
      expected_revision: nil,
      snapshot: {fields: {values: [1]}, phase: "pause"}
    )

    loaded = repository.load(thread_id)
    snapshot = workflow_contract_snapshot(loaded)
    fields = workflow_contract_value(snapshot, :fields)
    values = workflow_contract_value(fields, :values)

    begin
      values << 2
    rescue FrozenError
      nil
    end

    reloaded = repository.load(thread_id)
    reloaded_fields = workflow_contract_value(
      workflow_contract_snapshot(reloaded),
      :fields
    )
    expect(workflow_contract_value(reloaded_fields, :values)).to eq([1])
  end

  it "deletes only at the expected revision" do
    thread_id = "t1-#{SecureRandom.uuid}"
    repository.save(
      thread_id,
      expected_revision: nil,
      snapshot: {fields: {}, phase: "pause"}
    )

    expect do
      repository.delete(thread_id, expected_revision: 99)
    end.to raise_error(Phronomy::Persistence::ConflictError)

    repository.delete(thread_id, expected_revision: 1)
    expect(repository.load(thread_id)).to be_nil
  end
end
