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
end
