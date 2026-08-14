# frozen_string_literal: true

RSpec.shared_examples "a workflow state repository" do
  let(:repository) { persistence.workflow_states }

  it "returns nil for an unknown thread_id" do
    expect(repository.load("missing")).to be_nil
  end

  it "uses optimistic revisions for save" do
    expect(
      repository.save(
        "t1",
        expected_revision: nil,
        snapshot: {fields: {value: 1}, phase: "pause"}
      )
    ).to eq(1)

    expect(
      repository.save(
        "t1",
        expected_revision: 1,
        snapshot: {fields: {value: 2}, phase: "__end__"}
      )
    ).to eq(2)
  end

  it "rejects a stale expected_revision" do
    repository.save(
      "t1",
      expected_revision: nil,
      snapshot: {fields: {value: 1}, phase: "pause"}
    )

    expect do
      repository.save(
        "t1",
        expected_revision: nil,
        snapshot: {fields: {value: 2}, phase: "__end__"}
      )
    end.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "isolates stored snapshots from caller mutation" do
    repository.save(
      "t1",
      expected_revision: nil,
      snapshot: {fields: {values: [1]}, phase: "pause"}
    )

    loaded = repository.load("t1")
    loaded[:snapshot][:fields][:values] << 2

    expect(repository.load("t1")[:snapshot][:fields][:values]).to eq([1])
  end

  it "deletes only at the expected revision" do
    repository.save(
      "t1",
      expected_revision: nil,
      snapshot: {fields: {}, phase: "pause"}
    )

    expect do
      repository.delete("t1", expected_revision: 99)
    end.to raise_error(Phronomy::Persistence::ConflictError)

    repository.delete("t1", expected_revision: 1)
    expect(repository.load("t1")).to be_nil
  end
end
