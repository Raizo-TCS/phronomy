# frozen_string_literal: true

require "spec_helper"
require "weakref"

RSpec.describe Phronomy::Agent::ExecutionChange do
  let(:stores) { Phronomy::PersistenceComposition.in_memory }
  let(:klass) { Class.new(Phronomy::Agent::Base) { agent_definition id: "unit4-spi", version: 1 } }
  let(:agent) { klass.create(agent_id: "spi-agent", persistence: stores.agent) }
  let(:current) do
    record = Phronomy::Agent::JournalRecord.new(agent_id: agent.agent_id, kind: :input_received, channel: :external)
    value = Phronomy::Agent::AgentExecution.start(agent_root: agent.agent_root, input_record: record, execution_id: "spi-run")
    stores.agent.executions.create_active(value)
    value
  end
  let(:change) do
    described_class.new(agent: agent, current: current, root: agent.agent_root,
      kind: :dispatch, updated: current.with(status: :active, phase: :calling_llm))
  end

  after { Phronomy.reset_runtime! }

  it "publishes one result after the outer commit and rejects reuse" do
    updated = change.perform
    expect(stores.agent.observe_execution(agent_id: agent.agent_id, execution_id: current.execution_id)).to be_active
    expect(updated.execution_revision).to eq(current.execution_revision + 1)
    expect { change.perform }.to raise_error(Phronomy::ConfigurationError, /single-use/)
  end

  it "cannot publish from a successful nested savepoint" do
    current
    expect { stores.coordinator.atomic { change.perform } }.to raise_error(Phronomy::Persistence::TransactionError)
    expect(stores.agent.executions.load(current.execution_id).to_h).to eq(current.to_h)
  end

  it "rejects another coordinator without mutation" do
    other = Phronomy::PersistenceComposition.in_memory
    current
    expect { other.coordinator.atomic { |scope| change.prepare_in(scope) } }.to raise_error(Phronomy::Persistence::TransactionError)
    expect(stores.agent.executions.load(current.execution_id).to_h).to eq(current.to_h)
  end

  it "requires preparation in the exact synchronous scope" do
    current
    expect { stores.coordinator.atomic { |scope| change.commit_in(scope) } }.to raise_error(Phronomy::ConfigurationError)
    expect(stores.agent.executions.load(current.execution_id).to_h).to eq(current.to_h)
  end

  it "rejects cross-thread participation" do
    owned = change
    stores.coordinator.atomic do |scope|
      error = Thread.new {
        begin
          owned.prepare_in(scope)
        rescue
          $!
        end
      }.value
      expect(error).to be_a(Phronomy::Persistence::TransactionError)
    end
  end

  it "rechecks a changed execution revision before saving" do
    owned = change
    stores.agent.executions.save(current.execution_id, expected_revision: current.execution_revision,
      execution: current.with(status: :active))
    expect { owned.perform }.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "distinguishes preparing from a terminal observation" do
    current
    observed = stores.agent.observe_execution(agent_id: agent.agent_id, execution_id: current.execution_id)
    expect(observed).to be_active
    expect(observed).to be_continuable
    expect(observed).not_to be_terminal
  end

  it "records cancellation without changing the captured execution revision" do
    original = current
    stores.agent.request_cancellation(agent_id: agent.agent_id, execution_id: original.execution_id)
    expect(stores.agent.executions.load(original.execution_id).execution_revision).to eq(original.execution_revision)
    expect(stores.agent.observe_execution(agent_id: agent.agent_id, execution_id: original.execution_id)).not_to be_continuable
  end

  it "rejects a participant version mismatch before any dispatch change" do
    extension = Phronomy::Agent::ExecutionExtensionState.new(binding_key: "example", binding_version: 1)
    value = current.with(metadata: {"execution_extension" => extension.to_h})
    stores.agent.executions.save(current.execution_id, expected_revision: current.execution_revision, execution: value)
    participant = double(binding: extension.with(binding_version: 2))
    expect do
      described_class.new(agent: agent, current: value, root: agent.agent_root, kind: :dispatch,
        updated: value.with(status: :active), config: {phronomy_execution_participant: participant})
    end.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    expect(stores.agent.executions.load(value.execution_id).to_h).to eq(value.to_h)
  end

  [nil, :before_commit, :after_commit].each do |failure_point|
    it "releases completed change wiring while preserving its result, failure=#{failure_point.inspect}" do
      execution, root, persistence = current, agent.agent_root, stores.agent
      change_type = described_class
      retained, references, result, error, calls = Thread.new do
        owner = Struct.new(:agent_id, :persistence).new(execution.agent_id, persistence)
        writer_owner = Object.new
        participant = Class.new do
          attr_reader :commits, :readbacks

          def initialize(failure_point)
            @failure_point = failure_point
            @commits = @readbacks = 0
          end

          def commit(change)
            @commits += 1
            change.coordinator.atomic do |scope|
              change.prepare_in(scope)
              raise IOError, "before commit" if @failure_point == :before_commit
              change.commit_in(scope)
            end
            raise IOError, "lost commit response" if @failure_point == :after_commit
          end

          def guard_change(_change, _scope)
            @readbacks += 1
          end

          def change_evidence(_change, _scope) = "participant evidence"
        end.new(failure_point)
        item = change_type.new(agent: owner, current: execution, root: root,
          kind: :dispatch, updated: execution.with(status: :active),
          config: {phronomy_execution_participant: participant}, &writer_owner.method(:to_s))
        refs = [owner, writer_owner, participant].map { |value| WeakRef.new(value) }
        value = failure = nil
        begin
          value = item.perform
        rescue => caught
          failure = caught
        end
        [item, refs, value, failure, [participant.commits, participant.readbacks]]
      end.value

      3.times { GC.start }
      expect(references.none?(&:weakref_alive?)).to be(true)
      expect(retained.agent_id).to eq(execution.agent_id)
      expect(retained.kind).to eq(:dispatch)
      expect(calls).to eq([1, (failure_point == :after_commit) ? 1 : 0])
      if failure_point == :before_commit
        expect(error).to be_a(IOError)
        expect(error.message).to eq("before commit")
        expect(result).to be_nil
        expect(persistence.executions.load(execution.execution_id).to_h).to eq(execution.to_h)
      else
        expect(error).to be_nil
        expect(result.execution_revision).to eq(execution.execution_revision + 1)
        expect(persistence.executions.load(execution.execution_id).to_h).to eq(result.to_h)
      end
      expect { retained.perform }.to raise_error(Phronomy::ConfigurationError, /single-use/)
    end
  end
end
