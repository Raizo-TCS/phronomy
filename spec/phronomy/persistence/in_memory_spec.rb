# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Persistence::InMemory do
  subject(:persistence) { described_class.new }

  let(:root) do
    Phronomy::Agent::AgentRoot.create(
      agent_id: "agent-1",
      agent_definition_id: "test-agent",
      definition_version: 1
    )
  end

  it "rolls back all logical stores as one transaction" do
    expect do
      persistence.transaction do |tx|
        tx.agents.create(root)
        tx.contents.put_text("temporary")
        raise "rollback"
      end
    end.to raise_error("rollback")

    expect { persistence.agents.load(root.agent_id) }
      .to raise_error(Phronomy::Persistence::NotFoundError)
    temporary_id = "sha256:#{Digest::SHA256.hexdigest("temporary")}"
    expect(persistence.contents.exist?(temporary_id)).to be(false)
  end

  it "uses ExecutionRepository as atomic Agent admission" do
    persistence.transaction { |tx| tx.agents.create(root) }
    input_ref = persistence.contents.put_text("hello")
    input_record = Phronomy::Agent::JournalRecord.new(
      agent_id: root.agent_id,
      kind: :input_received,
      channel: :external,
      role: :user,
      content_ref: input_ref
    )
    first = Phronomy::Agent::AgentExecution.start(
      agent_root: root,
      input_record: input_record
    )
    second = Phronomy::Agent::AgentExecution.start(
      agent_root: root,
      input_record: input_record
    )

    persistence.transaction { |tx| tx.executions.create_active(first) }
    expect do
      persistence.transaction { |tx| tx.executions.create_active(second) }
    end.to raise_error(Phronomy::AgentBusyError)
  end

  describe "workflow_states" do
    it "creates and advances optimistic revisions" do
      revision = persistence.workflow_states.save(
        "workflow-1",
        expected_revision: nil,
        snapshot: {fields: {count: 1}, phase: "pause"}
      )
      expect(revision).to eq(1)

      record = persistence.workflow_states.load("workflow-1")
      expect(record[:revision]).to eq(1)
      expect(record[:snapshot]).to eq(
        fields: {count: 1},
        phase: "pause"
      )

      revision = persistence.workflow_states.save(
        "workflow-1",
        expected_revision: 1,
        snapshot: {fields: {count: 2}, phase: "__end__"}
      )
      expect(revision).to eq(2)
      expect(persistence.workflow_states.load("workflow-1")[:revision]).to eq(2)
    end

    it "rejects stale saves instead of overwriting a newer snapshot" do
      persistence.workflow_states.save(
        "workflow-1",
        expected_revision: nil,
        snapshot: {fields: {count: 1}, phase: "pause"}
      )

      expect do
        persistence.workflow_states.save(
          "workflow-1",
          expected_revision: nil,
          snapshot: {fields: {count: 99}, phase: "__end__"}
        )
      end.to raise_error(Phronomy::Persistence::ConflictError)

      expect(
        persistence.workflow_states.load("workflow-1")[:snapshot][:fields][:count]
      ).to eq(1)
    end

    it "returns copies so caller mutation cannot alter stored state" do
      persistence.workflow_states.save(
        "workflow-1",
        expected_revision: nil,
        snapshot: {fields: {items: ["a"]}, phase: "pause"}
      )

      loaded = persistence.workflow_states.load("workflow-1")
      loaded[:snapshot][:fields][:items] << "caller-mutation"

      expect(
        persistence.workflow_states.load("workflow-1")[:snapshot][:fields][:items]
      ).to eq(["a"])
    end

    it "supports non-Marshalable Workflow values without breaking Agent transactions" do
      callable = -> { :ok }
      persistence.workflow_states.save(
        "workflow-proc",
        expected_revision: nil,
        snapshot: {fields: {callable: callable}, phase: "pause"}
      )

      persistence.transaction do |tx|
        tx.agents.create(root)
      end

      record = persistence.workflow_states.load("workflow-proc")
      expect(record[:snapshot][:fields][:callable]).to respond_to(:call)
      expect(record[:snapshot][:fields][:callable].call).to eq(:ok)
    end

    it "rolls Agent and Workflow durable state back in the same transaction" do
      expect do
        persistence.transaction do |tx|
          tx.agents.create(root)
          tx.workflow_states.save(
            "workflow-1",
            expected_revision: nil,
            snapshot: {fields: {count: 1}, phase: "pause"}
          )
          raise "rollback-all"
        end
      end.to raise_error("rollback-all")

      expect { persistence.agents.load(root.agent_id) }
        .to raise_error(Phronomy::Persistence::NotFoundError)
      expect(persistence.workflow_states.load("workflow-1")).to be_nil
    end
  end

  describe "durable owner guardrails" do
    it "checks Agent revision and Journal position without returning replacement state" do
      persistence.agents.create(root)
      expect(
        persistence.assert_agent_watermark!(
          agent_id: root.agent_id,
          agent_revision: root.agent_revision,
          journal_position: 0
        )
      ).to be(true)

      advanced = root.with(agent_revision: root.agent_revision + 1)
      persistence.agents.save(
        root.agent_id,
        expected_revision: root.agent_revision,
        root: advanced
      )

      expect do
        persistence.assert_agent_watermark!(
          agent_id: root.agent_id,
          agent_revision: root.agent_revision,
          journal_position: 0
        )
      end.to raise_error(Phronomy::Persistence::ConflictError, /agent revision/)
    end

    it "rejects a Journal position advance even when Agent revision is unchanged" do
      persistence.agents.create(root)
      persistence.journals.append(
        root.agent_id,
        expected_position: 0,
        records: [
          Phronomy::Agent::JournalRecord.new(
            agent_id: root.agent_id,
            kind: :knowledge,
            channel: :context,
            role: :user,
            content_ref: persistence.contents.put_text("fact")
          )
        ]
      )

      expect do
        persistence.assert_agent_watermark!(
          agent_id: root.agent_id,
          agent_revision: root.agent_revision,
          journal_position: 0
        )
      end.to raise_error(Phronomy::Persistence::ConflictError, /journal position/)
    end
  end

  it "does not expose transient activations as a Persistence repository" do
    expect(persistence).not_to respond_to(:activations)
  end
end
