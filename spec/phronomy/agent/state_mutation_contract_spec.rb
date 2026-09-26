# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent initial and explicit state mutation contract" do
  let(:persistence) { Phronomy::Persistence.in_memory }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "state-mutation-contract", version: 1
    end
  end
  let(:agent) { agent_class.new(persistence: persistence) }

  def persisted_records(id)
    persistence.journals.read(id, limit: 100)
  end

  def fail_in_transaction(repository, operation, error)
    allow(persistence).to receive(:transaction).and_wrap_original do |original, &block|
      original.call do |tx|
        allow(tx.public_send(repository)).to receive(operation).and_raise(error)
        block.call(tx)
      end
    end
  end

  it "creates an empty root without a journal append or revision advance" do
    allow(persistence).to receive(:transaction).and_wrap_original do |original, &block|
      original.call do |tx|
        expect(tx.agents).to receive(:create).once.and_call_original
        expect(tx.agents).not_to receive(:save)
        expect(tx.journals).not_to receive(:append)
        block.call(tx)
      end
    end
    expect(agent.agent_root.agent_revision).to eq(0)
    expect(agent.agent_root.context_revision).to eq(0)
    expect(agent.agent_root.journal_position).to eq(0)
    expect(agent.journal_projection.records).to be_empty
  end

  it "stores imported text, JSON and knowledge in order before publishing initial state" do
    imported = Phronomy::Agent::ContextImporter.import_messages([
      {role: :user, content: "question"}, {role: :assistant, content: "answer"}
    ])
    instance = agent_class.new(persistence: persistence, context: imported, knowledge: [123, "fact"], metadata: {"origin" => "test"})
    root = instance.agent_root
    records = instance.journal_projection.records
    expect(records.map(&:kind)).to eq(%i[external_message assistant_message knowledge knowledge])
    expect(records.map(&:context_generation)).to eq([0, 0, 0, 0])
    expect(records.map(&:context_candidate)).to eq([true, true, true, true])
    expect(persistence.contents.fetch_text(records[0].content_ref)).to eq("question")
    expect(persistence.contents.fetch_json(records[1].content_ref).fetch("content")).to eq("answer")
    expect(records.last(2).map { |record| persistence.contents.fetch_text(record.content_ref) }).to eq(["123", "fact"])
    expect([root.agent_revision, root.context_revision, root.journal_position]).to eq([1, 1, 4])
    expect(root.metadata).to eq("origin" => "test")
    expect(persistence.agents.load(instance.agent_id).to_h).to eq(root.to_h)
    expect(records).to be_frozen
  end

  [[:contents, :put_text], [:journals, :append], [:agents, :save]].each do |repository, operation|
    it "rolls back creation and preserves the error when #{repository}.#{operation} fails" do
      error = ArgumentError.new("creation rejected")
      fail_in_transaction(repository, operation, error)
      expect { agent_class.new(agent_id: "failed-create", persistence: persistence, knowledge: ["fact"]) }
        .to raise_error { |actual| expect(actual).to equal(error) }
      expect { persistence.agents.load("failed-create") }.to raise_error(Phronomy::Persistence::NotFoundError)
      expect(persisted_records("failed-create")).to be_empty
    end
  end

  it "rejects an unsupported imported content format inside the initial transaction" do
    record = Phronomy::Agent::ContextImporter::ImportedRecord.new(
      kind: :external_message, channel: :external, role: :user,
      content: "bad", content_format: :binary, metadata: {}
    )
    context = Phronomy::Agent::ContextImporter::ImportedContext.new(records: [record])
    expect { agent_class.new(agent_id: "bad-import", persistence: persistence, context: context) }
      .to raise_error(ArgumentError, /unsupported imported content format: :binary/)
    expect { persistence.agents.load("bad-import") }.to raise_error(Phronomy::Persistence::NotFoundError)
  end

  it "uses the live root and publishes journal then root only after the transaction returns" do
    current = agent.agent_root
    before_records = agent.send(:_journal_records_snapshot)
    events = []
    allow(persistence).to receive(:transaction).and_wrap_original do |original, &block|
      original.call do |tx|
        expect(tx.agents).not_to receive(:load)
        expect(tx.executions).to receive(:assert_idle!).with(agent.agent_id).ordered.and_call_original
        expect(tx.contents).to receive(:put_text).with("123").ordered.and_call_original
        expect(tx.journals).to receive(:append).with(agent.agent_id, expected_position: 0, records: anything).ordered.and_call_original
        expect(tx.agents).to receive(:save).with(agent.agent_id, expected_revision: 0, root: anything).ordered.and_call_original
        block.call(tx)
        expect(agent.agent_root).to equal(current)
        expect(agent.send(:_journal_records_snapshot)).to equal(before_records)
      end
      events << :transaction_return
      :ignored_transaction_return
    end
    allow(agent).to receive(:_append_journal_records).and_wrap_original do |original, records|
      events << :journal_publication
      expect(agent.agent_root).to equal(current)
      original.call(records)
    end
    expect(agent.add_knowledge(123, metadata: nil)).to equal(agent)
    expect(events).to eq(%i[transaction_return journal_publication])
    expect(agent.agent_root).not_to equal(current)
    expect(agent.journal_projection.records.last.metadata).to eq({})
    expect(agent.send(:_journal_records_snapshot)).to be_frozen
    expect(persistence.agents.load(agent.agent_id).to_h).to eq(agent.agent_root.to_h)
  end

  {
    clear_transcript!: [:transcript_cleared, 1, 1, :idle],
    clear_knowledge!: [:knowledge_cleared, 1, 0, :idle],
    reset_context!: [:context_reset, 1, 1, :idle],
    close!: [:agent_closed, 0, 0, :closed]
  }.each do |operation, (kind, context_revision, generation, status)|
    it "preserves the state event and revision rules of #{operation}" do
      instance = agent
      result = instance.public_send(operation)
      root = instance.agent_root
      record = instance.journal_projection.records.last
      expect(result).to equal(root)
      expect([root.agent_revision, root.context_revision, root.journal_position]).to eq([1, context_revision, 1])
      expect(root.transcript_generation).to eq(generation)
      expect(root.lifecycle_status).to eq(status)
      expect([record.kind, record.channel, record.context_generation, record.context_candidate]).to eq([kind, :state, 0, false])
      expect(persistence.agents.load(instance.agent_id).to_h).to eq(root.to_h)
    end
  end

  %i[add_knowledge clear_transcript! clear_knowledge! reset_context! close!].each do |operation|
    it "rejects #{operation} before writes when an execution is active" do
      current = agent.agent_root
      error = Phronomy::AgentBusyError.new("active execution")
      allow(persistence).to receive(:transaction).and_wrap_original do |original, &block|
        original.call do |tx|
          expect(tx.executions).to receive(:assert_idle!).and_raise(error)
          expect(tx.contents).not_to receive(:put_text)
          expect(tx.journals).not_to receive(:append)
          expect(tx.agents).not_to receive(:save)
          block.call(tx)
        end
      end
      args = (operation == :add_knowledge) ? ["fact"] : []
      expect { agent.public_send(operation, *args) }.to raise_error { |actual| expect(actual).to equal(error) }
      expect(agent.agent_root).to equal(current)
      expect(agent.journal_projection.records).to be_empty
    end
  end

  %i[add_knowledge reset_context!].each do |operation|
    it "rolls back journal and keeps live state on a save failure in #{operation}" do
      current = agent.agent_root
      before_records = agent.send(:_journal_records_snapshot)
      error = Phronomy::Persistence::ConflictError.new("stale root")
      fail_in_transaction(:agents, :save, error)
      args = (operation == :add_knowledge) ? ["fact"] : []
      expect { agent.public_send(operation, *args) }.to raise_error { |actual| expect(actual).to equal(error) }
      expect(agent.agent_root).to equal(current)
      expect(agent.send(:_journal_records_snapshot)).to equal(before_records)
      expect(persisted_records(agent.agent_id)).to be_empty
      expect(persistence.agents.load(agent.agent_id).to_h).to eq(current.to_h)
    end
  end

  it "runs the proposed mutation after append and rolls back when the block fails" do
    current = agent.agent_root
    error = RuntimeError.new("mutation failed")
    appended = false
    allow(persistence).to receive(:transaction).and_wrap_original do |original, &block|
      original.call do |tx|
        allow(tx.journals).to receive(:append).and_wrap_original do |append, *args, **kwargs|
          appended = true
          append.call(*args, **kwargs)
        end
        expect(tx.agents).not_to receive(:save)
        block.call(tx)
      end
    end
    expect {
      agent.send(:mutate_context!, :context_reset) do |root|
        expect(root).to equal(current)
        expect(appended).to be(true)
        raise error
      end
    }.to raise_error { |actual| expect(actual).to equal(error) }
    expect(agent.agent_root).to equal(current)
    expect(persisted_records(agent.agent_id)).to be_empty
  end

  [0, 7].each do |proposed_revision|
    it "keeps the existing context-revision fallback for proposed #{proposed_revision}" do
      result = agent.send(:mutate_context!, :context_reset) do |root|
        root.with(agent_revision: root.agent_revision + 1, context_revision: proposed_revision)
      end
      expect(result.context_revision).to eq(proposed_revision.zero? ? 1 : 7)
    end
  end

  it "does not publish when the backend raises after the transaction block" do
    current = agent.agent_root
    error = RuntimeError.new("commit failed")
    allow(persistence).to receive(:transaction).and_wrap_original do |original, &block|
      original.call do |tx|
        block.call(tx)
        raise error
      end
    end
    expect { agent.add_knowledge("fact") }.to raise_error { |actual| expect(actual).to equal(error) }
    expect(agent.agent_root).to equal(current)
    expect(agent.journal_projection.records).to be_empty
    expect(persisted_records(agent.agent_id)).to be_empty
  end

  it "leaves the root unchanged if local journal publication fails after commit" do
    current = agent.agent_root
    error = RuntimeError.new("local publication failed")
    expect(agent).to receive(:_append_journal_records).and_raise(error)
    expect { agent.add_knowledge("fact") }.to raise_error { |actual| expect(actual).to equal(error) }
    expect(agent.agent_root).to equal(current)
    expect(persistence.agents.load(agent.agent_id).agent_revision).to eq(1)
    expect(persisted_records(agent.agent_id).length).to eq(1)
  end
end
