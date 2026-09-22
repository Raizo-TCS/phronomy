# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::InitialPreparation do
  # F1 injection: the delegate commits, but its response does not reach the caller.
  class PreparationResponseLoss < Phronomy::Persistence
    attr_reader :transaction_count

    def initialize(delegate)
      @delegate = delegate
      super(backend: delegate.backend)
      arm(nil)
    end

    def arm(transaction)
      @transaction_count = 0
      @lost_response_transaction = transaction
    end

    def transaction
      @transaction_count += 1
      result = @delegate.transaction { |tx| yield tx }
      if @transaction_count == @lost_response_transaction
        raise IOError, "preparation response lost after commit"
      end
      result
    end
  end

  let(:store) { Phronomy::Persistence.in_memory }
  let(:persistence) { PreparationResponseLoss.new(store) }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "initial-preparation-#{SecureRandom.hex(6)}", version: 1
      model "local-model"
      context_window 4096
      max_output_tokens 512
    end
  end
  let(:agent) { agent_class.create(agent_id: "initial-agent", persistence: persistence) }
  let(:worker) { described_class.new(agent: agent, persistence: persistence) }

  after do
    Phronomy.reset_runtime!
  end

  def operation(config = {})
    described_class::Command.new(
      root: agent.agent_root,
      journal_records: agent.send(:_journal_records_snapshot),
      input: "hello",
      config: config.freeze,
      preparation_replayable: true
    )
  end

  def observe_policy(&observe)
    policy = Class.new(Phronomy::Agent::ContextPolicy) do
      define_method(:call) do |input|
        observe.call
        Phronomy::Agent::ContextPolicies::Default.instance.call(input)
      end
    end.new
    agent.class.context_policy(policy)
  end

  def admitted(config: {}, replayable: true, mode: :invoke)
    execution, root = worker.send(
      :admit_execution, "hello", root: agent.agent_root, mode: mode,
      config: config, preparation_replayable: replayable
    )
    described_class::RecoveryCommand.new(
      execution: execution, root: root,
      journal_records: agent.send(:_journal_records_snapshot)
    )
  end

  it "runs filtering and Policy outside transactions and materializes only confirmed state" do
    command = operation
    events = []
    transaction_open = false
    observe_policy do
      expect(transaction_open).to be(false)
      events << :policy
    end
    allow(persistence).to receive(:transaction).and_wrap_original do |original, &action|
      transaction_open = true
      events << :transaction_started
      original.call(&action)
    ensure
      transaction_open = false
      events << :transaction_finished
    end
    allow(agent).to receive(:run_input_filters!).and_wrap_original do |original, input|
      expect(transaction_open).to be(false)
      events << :filter
      original.call(input)
    end
    allow(agent).to receive(:run_before_llm_input_hooks).and_wrap_original do |original, **kwargs|
      expect(transaction_open).to be(false)
      events << :hook
      original.call(**kwargs)
    end
    allow(Phronomy::Agent::RubyLLMMaterializer).to receive(:new).and_wrap_original do |original, **kwargs|
      materializer = original.call(**kwargs)
      allow(materializer).to receive(:materialize).and_wrap_original do |method, **args|
        expect(transaction_open).to be(false)
        expect(persistence.executions.list_active(agent.agent_id).first.phase).to eq(:calling_llm)
        events << :materialize
        method.call(**args)
      end
      materializer
    end

    result = worker.prepare(command)

    expect(result.admission_outcome).to eq(:active)
    expect(result.error).to be_nil
    expect(events).to eq([:transaction_started, :transaction_finished, :filter, :hook,
      :policy, :transaction_started, :transaction_finished, :materialize])
    expect(agent.agent_root).to equal(command.root)
    expect(agent.send(:_journal_records_snapshot)).to eq(command.journal_records)
  end

  it "reports extraction failure before admission without claiming an uncertain save" do
    command = operation
    persistence.arm(nil)
    error = IOError.new("input extraction failed")
    allow(agent).to receive(:extract_message).and_raise(error)

    result = worker.prepare(command)

    expect(result.admission_outcome).to eq(:not_established)
    expect(result.error).to equal(error)
    expect(result.execution).to be_nil
    expect(persistence.transaction_count).to eq(0)
  end

  it "releases a known failed durable admission without running input filters" do
    command = operation
    allow(store.executions).to receive(:create_active).and_raise(Phronomy::Storage::ConflictError, "stale root")
    expect(agent).not_to receive(:run_input_filters!)

    result = worker.prepare(command)

    expect(result.admission_outcome).to eq(:not_established)
    expect(persistence.executions.list_active(agent.agent_id)).to be_empty
    expect(persistence.agents.load(agent.agent_id).to_h).to eq(command.root.to_h)
  end

  it "keeps Runtime admission closed after a lost durable admission response" do
    agent
    persistence.arm(1)
    expect(agent).not_to receive(:run_input_filters!)

    expect { agent.invoke_async("hello").wait_result(timeout: 2) }
      .to raise_error(IOError, /response lost/)
    expect { agent.invoke_async("again").wait_result(timeout: 2) }
      .to raise_error(Phronomy::AgentBusyError)

    expect(persistence.transaction_count).to eq(1)
    stored = persistence.executions.list_active(agent.agent_id)
    expect(stored.length).to eq(1)
    expect(stored.first.status).to eq(:preparing)
  end

  it "does not advance its failure base after a lost active-commit response" do
    command = operation
    persistence.arm(2)
    expect(Phronomy::Agent::RubyLLMMaterializer).not_to receive(:new)

    expect { worker.prepare(command) }.to raise_error(Phronomy::Storage::ConflictError)

    stored = persistence.executions.list_active(agent.agent_id).first
    expect(stored.status).to eq(:active)
    expect(stored.execution_revision).to eq(1)
    expect(stored.metadata).to have_key("manifest_ref")
    # The attempted failure transaction rolls back its Journal append on the
    # stale revision. It cannot turn the uncertain committed state into failure.
    root = persistence.agents.load(agent.agent_id)
    expect(root.journal_position).to eq(command.root.journal_position)
    expect(root.lifecycle_status).to eq(:active)
    expect(persistence.journals.read(agent.agent_id)).to be_empty
  end

  it "propagates a lost failure-commit response without returning a confirmed terminal result" do
    command = operation
    persistence.arm(2)
    allow(agent).to receive(:run_input_filters!).and_raise(ArgumentError, "filter failed")

    expect { worker.prepare(command) }.to raise_error(IOError, /response lost/)

    expect(persistence.executions.list_active(agent.agent_id)).to be_empty
    root = persistence.agents.load(agent.agent_id)
    expect(root.lifecycle_status).to eq(:idle)
    expect(persistence.journals.read(agent.agent_id).last.kind).to eq(:execution_failed)
    expect(agent.agent_root).to equal(command.root)
  end

  it "terminalizes a materialization failure from the confirmed active revision" do
    command = operation
    failure = ArgumentError.new("cannot materialize committed input")
    allow(Phronomy::Agent::RubyLLMMaterializer).to receive(:new).and_wrap_original do |original, **kwargs|
      instance = original.call(**kwargs)
      allow(instance).to receive(:materialize).and_raise(failure)
      instance
    end

    result = worker.prepare(command)

    expect(result.admission_outcome).to eq(:terminal)
    expect(result.execution.status).to eq(:failed)
    expect(result.execution.execution_revision).to eq(2)
    expect(result.error).to equal(failure)
    expect(result.appended_records.map(&:kind)).to eq([:input_received, :external_message, :execution_failed])
    expect(result.appended_records).to all(have_attributes(context_candidate: false))
    expect(result.root.journal_position).to eq(command.root.journal_position + result.appended_records.length)
    expect(persistence.executions.load(result.execution.execution_id).to_h).to eq(result.execution.to_h)
    expect(agent.agent_root).to equal(command.root)
  end

  it "commits cancellation detected after Policy without activating or materializing the call" do
    token = Phronomy::Concurrency::CancellationToken.new
    command = operation(cancellation_token: token)
    observe_policy { token.cancel! }
    expect(Phronomy::Agent::RubyLLMMaterializer).not_to receive(:new)

    result = worker.prepare(command)

    expect(result.admission_outcome).to eq(:terminal)
    expect(result.execution.status).to eq(:cancelled)
    expect(result.execution.execution_revision).to eq(1)
    expect(result.appended_records.last.kind).to eq(:execution_cancelled)
    expect(result.execution.metadata).not_to have_key("manifest_ref")
  end

  it "retains the blocked outcome and audit kind when an input filter rejects the request" do
    command = operation
    allow(agent).to receive(:run_input_filters!).and_raise(Phronomy::FilterBlockError, "blocked input")

    result = worker.prepare(command)

    expect(result.admission_outcome).to eq(:terminal)
    expect(result.execution.status).to eq(:blocked)
    expect(result.appended_records.last.kind).to eq(:execution_blocked)
    expect(result.appended_records).to all(have_attributes(context_candidate: false))
  end

  it "revalidates the admitted watermark after Policy without overwriting a newer root" do
    command = operation
    advanced_root = nil
    observe_policy do
      stored = persistence.agents.load(agent.agent_id)
      advanced_root = stored.with(agent_revision: stored.agent_revision + 1)
      persistence.agents.save(agent.agent_id, expected_revision: stored.agent_revision, root: advanced_root)
    end
    expect(Phronomy::Agent::RubyLLMMaterializer).not_to receive(:new)

    expect { worker.prepare(command) }.to raise_error(Phronomy::Storage::ConflictError)

    expect(persistence.agents.load(agent.agent_id).to_h).to eq(advanced_root.to_h)
    expect(persistence.executions.list_active(agent.agent_id).first.status).to eq(:preparing)
    expect(persistence.journals.read(agent.agent_id)).to be_empty
  end

  it "recovers the same admitted execution from frozen durable inputs without admitting again" do
    command = admitted(config: {durable_context: {"tenant" => {"roles" => ["reader"]}}}, mode: :stream)
    expect(store.executions).not_to receive(:create_active)

    result = worker.recover(command)

    expect(result.admission_outcome).to eq(:active)
    expect(result.execution.execution_id).to eq(command.execution.execution_id)
    expect(result.execution.execution_revision).to eq(command.execution.execution_revision + 1)
    expect(result.config.fetch(:phronomy_recovery_mode)).to eq(:stream)
    expect(result.config).to be_frozen
    context = result.config.fetch(:durable_context)
    expect(context).to eq("tenant" => {"roles" => ["reader"]})
    expect(context).to be_frozen
    expect(context.fetch("tenant").fetch("roles")).to be_frozen
  end

  it "rejects unreplayable preparation before reading content or running application code" do
    command = admitted(replayable: false)
    expect(persistence.contents).not_to receive(:fetch_text)
    expect(agent).not_to receive(:run_input_filters!)

    expect { worker.recover(command) }
      .to raise_error(Phronomy::ExecutionRehydrationRequiredError, /replay-safe/)
  end

  it "rejects malformed saved durable context without terminalizing the admitted execution" do
    command = admitted(config: {durable_context: []})
    expect(agent).not_to receive(:run_input_filters!)
    expect(store.executions).not_to receive(:save)

    expect { worker.recover(command) }
      .to raise_error(Phronomy::ExecutionRehydrationRequiredError, /non-Hash/)
    expect(persistence.executions.load(command.execution.execution_id).status).to eq(:preparing)
  end

  it "propagates an input read failure during recovery without retry or a failure commit" do
    command = admitted
    expect(persistence.contents).to receive(:fetch_text).once.and_raise(IOError, "read unavailable")
    expect(persistence).not_to receive(:transaction)

    expect { worker.recover(command) }.to raise_error(IOError, "read unavailable")
  end
end
