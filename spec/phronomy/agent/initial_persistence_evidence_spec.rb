# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::InitialPersistenceEvidence do
  let(:persistence) { Phronomy::PersistenceComposition.in_memory.agent }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "initial-proof", version: 1
    end
  end
  let(:agent) { agent_class.create(agent_id: "initial-proof-owner", persistence: persistence) }
  let(:execution_id) { "initial-proof-execution" }
  let(:authority) do
    Class.new do
      attr_accessor :current, :owner_current
      attr_reader :guards, :assertions, :cleanup_assertions

      def initialize
        @current, @owner_current, @guards, @assertions, @cleanup_assertions = true, true, 0, 0, 0
      end

      def guard(scope:, persistence:)
        raise "Wrong guard scope" unless scope.outermost? && persistence
        @guards += 1
      end

      def assert_current!(scope:, persistence:)
        raise "Wrong authority scope" unless scope.outermost? && persistence
        @assertions += 1
        raise Phronomy::Persistence::StateConflictError, "Original reservation changed" unless current
      end

      def assert_cleanup!(scope:, persistence:)
        raise "Wrong cleanup scope" unless scope.outermost? && persistence
        @cleanup_assertions += 1
        raise Phronomy::Persistence::StateConflictError, "Original cleanup owner changed" unless owner_current
      end
    end.new
  end

  def proposal(stage, owner_authority: nil, reservation: nil)
    root = agent.agent_root
    contents = described_class::Contents.new(persistence.contents)
    input_ref = contents.put_text("retained input")
    input = Phronomy::Agent::JournalRecord.new(agent_id: agent.agent_id, execution_id: execution_id,
      kind: :input_received, channel: :external, role: :user, content_ref: input_ref,
      context_generation: root.transcript_generation, context_candidate: false)
    initial = Phronomy::Agent::AgentExecution.start(agent_root: root, execution_id: execution_id,
      input_record: input, metadata: {"current_input_ref" => input_ref, "reservation" => reservation}.compact)
    current = nil
    appended = []
    if stage == :admission
      execution = initial
      next_root = root.with(agent_revision: root.agent_revision + 1, lifecycle_status: :active)
    else
      current = initial
      admitted = root.with(agent_revision: root.agent_revision + 1, lifecycle_status: :active)
      persistence.transaction do |records|
        records.executions.create_active(current)
        records.agents.save(agent.agent_id, expected_revision: root.agent_revision, root: admitted)
      end
      root = admitted
      if stage == :activation
        manifest_ref = contents.put_json("input" => input_ref, "call_sequence" => 1)
        execution = current.with(status: :active, phase: :calling_llm,
          metadata: current.metadata.merge("manifest_ref" => manifest_ref))
        next_root = root
      else
        error_ref = contents.put_json("class" => "IOError", "message" => "fixed preparation failure")
        audit = Phronomy::Agent::JournalRecord.new(agent_id: agent.agent_id, execution_id: execution_id,
          kind: :execution_failed, channel: :audit, content_ref: error_ref,
          context_generation: root.transcript_generation, context_candidate: false)
        appended = [input, audit]
        execution = current.with(status: :failed, phase: :failed, working_records: [], error_ref: error_ref)
        next_root = root.with(agent_revision: root.agent_revision + 1,
          journal_position: root.journal_position + appended.size, lifecycle_status: :idle)
      end
    end
    persistence.coordinator.atomic do |scope|
      described_class.capture(stage: stage, persistence: persistence, scope: scope, root: root,
        current_execution: current, execution: execution, next_root: next_root,
        content_writes: contents.writes, appended_records: appended, authority: owner_authority)
    end
  end

  def apply(proof)
    persistence.coordinator.atomic { |scope| proof.apply_in(persistence: persistence, scope: scope) }
  end

  [:admission, :activation, :failure].each do |stage|
    it "captures #{stage} before writing, then applies exact records and content once" do
      proof = proposal(stage)
      expect(proof.reconcile(persistence: persistence).disposition).to eq(:not_committed)
      expect(proof.content_writes).not_to be_empty
      expect(proof.content_writes.all? { |write| persistence.contents.exist?(write.reference) }).to be(false)
      expect(proof).to be_frozen
      expect(proof.instance_variables).not_to include(:@scope, :@persistence, :@contents)
      expect { proof.before.fetch(:root)["agent_revision"] = 100 }.to raise_error(FrozenError)
      expect { proof.content_writes.first.bytes << "changed" }.to raise_error(FrozenError)

      apply(proof)
      expect(proof.reconcile(persistence: persistence).disposition).to eq(:committed)
      expect(persistence.executions.load(execution_id).to_h).to eq(proof.execution.to_h)
      expect(persistence.agents.load(agent.agent_id).to_h).to eq(proof.next_root.to_h)
      expect(persistence.journals.read(agent.agent_id).map(&:to_h)).to eq(proof.appended_records.map(&:to_h))
      expect_any_instance_of(Phronomy::Persistence::ContentRepository).not_to receive(:put)
      expect(proof.retry(persistence: persistence).disposition).to eq(:committed)
    end

    it "retains the #{stage} proposal across a rollback and retries only captured writes" do
      proof = proposal(stage)
      expect {
        persistence.coordinator.atomic do |scope|
          proof.apply_in(persistence: persistence, scope: scope)
          raise IOError, "rollback after all proposal writes"
        end
      }.to raise_error(IOError, "rollback after all proposal writes")
      expect(proof.reconcile(persistence: persistence).disposition).to eq(:not_committed)
      expect(proof.retry(persistence: persistence).disposition).to eq(:committed)
      expect(persistence.executions.load(execution_id).to_h).to eq(proof.execution.to_h)
    end

    it "does not write after the #{stage} pre-state changes" do
      proof = proposal(stage)
      root = persistence.agents.load(agent.agent_id)
      persistence.transaction do |records|
        records.agents.save(agent.agent_id, expected_revision: root.agent_revision,
          root: root.with(agent_revision: root.agent_revision + 1, metadata: {"unrelated" => true}))
      end
      expect_any_instance_of(Phronomy::Persistence::ContentRepository).not_to receive(:put)
      expect(proof.retry(persistence: persistence).disposition).to eq(:unknown)
      expect { apply(proof) }.to raise_error(Phronomy::Persistence::StateConflictError)
    end
  end

  it "buffers immutable bytes without saving and can read previously stored content" do
    stored = persistence.contents.put_text("existing")
    contents = described_class::Contents.new(persistence.contents)
    value = +"buffered"
    reference = contents.put_text(value)
    first_writes = contents.writes
    value << " changed"
    contents.put_json("later" => true)
    expect(first_writes.size).to eq(1)
    expect(first_writes).to be_frozen
    expect(first_writes.first).to be_frozen
    expect(contents.fetch_text(reference)).to eq("buffered")
    expect(contents.fetch_text(stored)).to eq("existing")
    expect(contents.exist?(reference)).to be(true)
    expect(persistence.contents.exist?(reference)).to be(false)
    returned = contents.fetch(reference)
    returned << " caller mutation"
    expect(contents.fetch_text(reference)).to eq("buffered")
  end

  it "preserves durable busy custody when another active execution precedes admission capture" do
    first = proposal(:admission)
    persistence.coordinator.atomic { |scope| first.apply_in(persistence: persistence, scope: scope) }

    expect { proposal(:admission) }
      .to raise_error(Phronomy::AgentBusyError, /durable active execution/)
    expect(persistence.executions.list_active(agent.agent_id).map(&:execution_id)).to eq([execution_id])
  end

  it "does not classify a competing active execution as admission absence" do
    proof = proposal(:admission)
    competitor = proof.execution.with(execution_id: "another-execution", execution_revision: 0, working_records: [])
    persistence.transaction { |records| records.executions.create_active(competitor) }
    expect(proof.reconcile(persistence: persistence).disposition).to eq(:unknown)
    expect_any_instance_of(Phronomy::Persistence::ContentRepository).not_to receive(:put)
    expect(proof.retry(persistence: persistence).disposition).to eq(:unknown)
  end

  it "does not capture reserved admission without its domain authority" do
    expect {
      proposal(:admission, reservation: {"kind" => "handoff", "main_agent_id" => "main"})
    }.to raise_error(ArgumentError, "Reserved initial persistence requires its captured authority")
    expect(persistence.active_executions(agent_id: agent.agent_id)).to be_empty
  end

  it "uses the captured authority for a reserved admission" do
    proof = proposal(:admission, owner_authority: authority,
      reservation: {"kind" => "handoff", "main_agent_id" => "main"})
    authority.current = false
    receipt = proof.retry(persistence: persistence)
    expect(receipt.disposition).to eq(:not_committed)
    expect(receipt.read_error).to be_a(Phronomy::Persistence::StateConflictError)
    expect(persistence.active_executions(agent_id: agent.agent_id)).to be_empty
  end

  it "does not treat an execution read failure as authoritative absence" do
    proof = proposal(:admission)
    allow_any_instance_of(Phronomy::Agent::Persistence::ExecutionRepository).to receive(:load).and_raise(IOError, "read unavailable")
    receipt = proof.reconcile(persistence: persistence)
    expect(receipt.disposition).to eq(:unknown)
    expect(receipt.read_error).to be_a(IOError)
  end

  it "rejects another Store before attempting a transaction" do
    proof = proposal(:admission)
    other = Phronomy::Agent::Store.new(coordinator: persistence.coordinator, records: Phronomy::Agent::Persistence::Records)
    expect(other.coordinator).not_to receive(:atomic)
    receipt = proof.reconcile(persistence: other)
    expect(receipt.disposition).to eq(:unknown)
    expect(receipt.read_error).to be_a(Phronomy::Persistence::StateConflictError)
  end

  it "requires an outer transaction for application" do
    proof = proposal(:admission)
    expect {
      persistence.coordinator.atomic do
        persistence.coordinator.atomic { |scope| proof.apply_in(persistence: persistence, scope: scope) }
      end
    }
      .to raise_error(Phronomy::Persistence::TransactionError)
  end

  it "keeps committed activation separate from lost current continuation authority" do
    proof = proposal(:activation, owner_authority: authority)
    apply(proof)
    authority.current = authority.owner_current = false
    receipt = proof.reconcile(persistence: persistence)
    expect(receipt.disposition).to eq(:committed)
    expect(receipt.read_error).to be_nil
    expect(receipt.continuation_error).to be_a(Phronomy::Persistence::StateConflictError)
    expect(proof.retry(persistence: persistence).disposition).to eq(:committed)
  end

  it "requires current authority for a failure write but not adoption of its committed terminal fact" do
    proof = proposal(:failure, owner_authority: authority)
    authority.current = authority.owner_current = false
    denied = proof.retry(persistence: persistence)
    expect(denied.disposition).to eq(:not_committed)
    expect(denied.read_error).to be_a(Phronomy::Persistence::StateConflictError)
    authority.owner_current = true
    expect(proof.retry(persistence: persistence).disposition).to eq(:committed)
    authority.current = false
    assertions = [authority.assertions, authority.cleanup_assertions]
    receipt = proof.reconcile(persistence: persistence)
    expect(receipt.disposition).to eq(:committed)
    expect(receipt.continuation_error).to be_nil
    expect([authority.assertions, authority.cleanup_assertions]).to eq(assertions)
  end

  it "retains the exact committed result when the retry response is lost" do
    proof = proposal(:admission)
    armed = true
    allow(persistence.coordinator).to receive(:atomic).and_wrap_original do |original, &block|
      value = original.call(&block)
      if armed
        armed = false
        raise IOError, "committed retry response lost"
      end
      value
    end
    receipt = proof.retry(persistence: persistence)
    expect(receipt.disposition).to eq(:committed)
    expect(receipt.original_error.message).to eq("committed retry response lost")
    expect(persistence.executions.load(execution_id).to_h).to eq(proof.execution.to_h)
  end

  it "refuses committed record evidence with missing captured content" do
    proof = proposal(:activation)
    apply(proof)
    reference = proof.content_writes.last.reference
    allow_any_instance_of(Phronomy::Persistence::ContentRepository).to receive(:fetch).and_wrap_original do |original, current|
      raise Phronomy::Persistence::NotFoundError, "content missing" if current == reference
      original.call(current)
    end
    receipt = proof.reconcile(persistence: persistence)
    expect(receipt.disposition).to eq(:unknown)
    expect(receipt.read_error).to be_a(Phronomy::Persistence::NotFoundError)
  end

  it "preserves pre-state classification but prevents activation writes after cancellation" do
    proof = proposal(:activation)
    persistence.request_cancellation(agent_id: agent.agent_id, execution_id: execution_id)
    expect(proof.reconcile(persistence: persistence).disposition).to eq(:not_committed)
    receipt = proof.retry(persistence: persistence)
    expect(receipt.disposition).to eq(:not_committed)
    expect(receipt.read_error).to be_a(Phronomy::CancellationError)
  end

  it "retains committed activation while independently denying continuation after cancellation" do
    proof = proposal(:activation)
    apply(proof)
    persistence.request_cancellation(agent_id: agent.agent_id, execution_id: execution_id)
    receipt = proof.reconcile(persistence: persistence)
    expect(receipt.disposition).to eq(:committed)
    expect(receipt.continuation_error).to be_a(Phronomy::CancellationError)
  end

  it "permits exact failure cleanup despite cancellation and later adopts its terminal fact" do
    proof = proposal(:failure, owner_authority: authority)
    authority.current = false
    persistence.request_cancellation(agent_id: agent.agent_id, execution_id: execution_id)
    receipt = proof.retry(persistence: persistence)
    expect(receipt.disposition).to eq(:committed)
    expect(receipt.continuation_error).to be_nil
    expect(persistence.executions.load(execution_id).status).to eq(:failed)
    expect(authority.assertions).to eq(0)
    expect(authority.cleanup_assertions).to eq(1)
  end

  it "does not overlook an extra journal suffix when comparing activation evidence" do
    proof = proposal(:activation)
    record = proof.execution.working_records.first
    persistence.transaction { |records| records.journals.append(agent.agent_id, expected_position: 0, records: [record]) }
    expect(proof.reconcile(persistence: persistence).disposition).to eq(:unknown)
  end
end
