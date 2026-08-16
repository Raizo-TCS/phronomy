# frozen_string_literal: true

require "securerandom"

RSpec.shared_examples "a Persistence backend" do
  let(:backend_agent_root) do
    Phronomy::Agent::AgentRoot.create(
      agent_id: "backend-agent-#{SecureRandom.uuid}",
      agent_definition_id: "contract-agent",
      definition_version: 1
    )
  end

  def build_backend_execution(root)
    record = Phronomy::Agent::JournalRecord.new(
      agent_id: root.agent_id,
      kind: :input_received,
      channel: :external,
      role: :user,
      context_candidate: false
    )
    Phronomy::Agent::AgentExecution.start(agent_root: root, input_record: record)
  end

  it "advertises every required capability" do
    Phronomy::Persistence::REQUIRED_CAPABILITIES.each do |name, required_value|
      expect(persistence.capabilities[name]).to eq(required_value)
    end
  end

  it "yields a transaction view that exposes the complete durable SPI" do
    persistence.transaction do |tx|
      expect(tx).to respond_to(
        :contents,
        :agents,
        :journals,
        :executions,
        :workflow_states,
        :assert_agent_watermark!
      )
    end
  end

  it "returns the transaction block result" do
    expect(persistence.transaction { |_tx| :contract_result }).to eq(:contract_result)
  end

  it "commits changes across durable repositories as one transaction" do
    root = backend_agent_root
    execution = build_backend_execution(root)
    workflow_id = "workflow-#{SecureRandom.uuid}"
    content_id = nil

    persistence.transaction do |tx|
      content_id = tx.contents.put_text("committed")
      tx.agents.create(root)
      appended = tx.journals.append(
        root.agent_id,
        expected_position: 0,
        records: [
          Phronomy::Agent::JournalRecord.new(
            agent_id: root.agent_id,
            kind: :knowledge,
            channel: :context,
            role: :user,
            content_ref: content_id,
            context_candidate: true
          )
        ]
      )
      tx.executions.create_active(execution)
      tx.workflow_states.save(
        workflow_id,
        expected_revision: nil,
        snapshot: {fields: {value: "committed"}, phase: "pause"}
      )

      updated_root = root.with(
        agent_revision: 1,
        journal_position: appended.length,
        lifecycle_status: :active
      )
      tx.agents.save(root.agent_id, expected_revision: 0, root: updated_root)
    end

    expect(persistence.contents.exist?(content_id)).to be(true)
    expect(persistence.agents.load(root.agent_id).agent_revision).to eq(1)
    expect(persistence.journals.head(root.agent_id)).to eq(1)
    expect(persistence.executions.load(execution.execution_id).execution_id)
      .to eq(execution.execution_id)
    expect(persistence.workflow_states.load(workflow_id)).not_to be_nil
  end

  it "rolls back all durable repositories when the transaction block raises" do
    root = backend_agent_root
    execution = build_backend_execution(root)
    workflow_id = "workflow-#{SecureRandom.uuid}"
    content_id = nil

    expect do
      persistence.transaction do |tx|
        content_id = tx.contents.put_text("temporary-#{SecureRandom.uuid}")
        tx.agents.create(root)
        tx.journals.append(
          root.agent_id,
          expected_position: 0,
          records: [
            Phronomy::Agent::JournalRecord.new(
              agent_id: root.agent_id,
              kind: :knowledge,
              channel: :context,
              role: :user,
              content_ref: content_id,
              context_candidate: true
            )
          ]
        )
        tx.executions.create_active(execution)
        tx.workflow_states.save(
          workflow_id,
          expected_revision: nil,
          snapshot: {fields: {value: "temporary"}, phase: "pause"}
        )
        raise "rollback-contract"
      end
    end.to raise_error("rollback-contract")

    expect(persistence.contents.exist?(content_id)).to be(false)
    expect do
      persistence.agents.load(root.agent_id)
    end.to raise_error(Phronomy::Persistence::NotFoundError)
    expect(persistence.journals.head(root.agent_id)).to eq(0)
    expect do
      persistence.executions.load(execution.execution_id)
    end.to raise_error(Phronomy::Persistence::NotFoundError)
    expect(persistence.workflow_states.load(workflow_id)).to be_nil
  end

  it "accepts the current Agent revision and Journal position watermark" do
    root = backend_agent_root
    persistence.agents.create(root)

    expect(
      persistence.assert_agent_watermark!(
        agent_id: root.agent_id,
        agent_revision: root.agent_revision,
        journal_position: root.journal_position
      )
    ).to be(true)
  end

  it "raises ConflictError when the durable Agent revision has advanced" do
    root = backend_agent_root
    persistence.agents.create(root)
    advanced = root.with(agent_revision: 1)
    persistence.agents.save(root.agent_id, expected_revision: 0, root: advanced)

    expect do
      persistence.assert_agent_watermark!(
        agent_id: root.agent_id,
        agent_revision: 0,
        journal_position: 0
      )
    end.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "raises ConflictError when the durable Journal position has advanced" do
    root = backend_agent_root
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
          context_candidate: true
        )
      ]
    )

    expect do
      persistence.assert_agent_watermark!(
        agent_id: root.agent_id,
        agent_revision: 0,
        journal_position: 0
      )
    end.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "rolls back earlier writes when a watermark precondition fails" do
    root = backend_agent_root
    persistence.agents.create(root)
    advanced = root.with(agent_revision: 1)
    persistence.agents.save(root.agent_id, expected_revision: 0, root: advanced)
    temporary_content_id = nil

    expect do
      persistence.transaction do |tx|
        temporary_content_id = tx.contents.put_text(
          "watermark-rollback-#{SecureRandom.uuid}"
        )
        tx.assert_agent_watermark!(
          agent_id: root.agent_id,
          agent_revision: 0,
          journal_position: 0
        )
      end
    end.to raise_error(Phronomy::Persistence::ConflictError)

    expect(persistence.contents.exist?(temporary_content_id)).to be(false)
  end
end
