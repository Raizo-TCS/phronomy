# frozen_string_literal: true

require "spec_helper"
require "timeout"

PREPARING_RECOVERY_HOOK_CONFIGS = Queue.new

class PreparingRecoverySpecAgent < Phronomy::Agent::Base
  agent_definition id: "preparing-recovery-spec-agent", version: 1
  model "test-model"
end

class PreparingRecoveryHookFailureAgent < Phronomy::Agent::Base
  agent_definition id: "preparing-recovery-hook-failure-agent", version: 1
  model "test-model"

  before_llm_input do |context|
    PREPARING_RECOVERY_HOOK_CONFIGS << context.config
    raise "intentional preparation replay failure"
  end
end

RSpec.describe "durable :preparing Agent recovery" do
  MISSING = Object.new.freeze

  after do
    Phronomy.reset_runtime!
  rescue
    nil
  end

  def install_preparing_execution(
    agent,
    persistence,
    replayable:,
    durable_context: MISSING,
    include_replayable_marker: true
  )
    root = agent.agent_root
    execution = next_root = nil

    persistence.transaction do |tx|
      input_ref = tx.contents.put_text("recover me")
      durable_context_ref = if !durable_context.equal?(MISSING)
        tx.contents.put_json(durable_context)
      end
      input_record = Phronomy::Agent::JournalRecord.new(
        agent_id: agent.agent_id,
        kind: :input_received,
        channel: :external,
        role: :user,
        content_ref: input_ref,
        context_generation: root.transcript_generation,
        context_candidate: false
      )
      metadata = {
        "current_input_ref" => input_ref,
        "durable_context_ref" => durable_context_ref,
        "pending_llm_call_id" => "preparing-recovery-llm",
        "invocation_mode" => "invoke",
        "recovery_contract_version" => 1
      }.compact
      metadata["preparation_replayable"] = replayable if
        include_replayable_marker
      execution = Phronomy::Agent::AgentExecution.start(
        agent_root: root,
        input_record: input_record,
        metadata: metadata
      )
      input_record = Phronomy::Agent::JournalRecord.from_h(
        input_record.to_h.merge("execution_id" => execution.execution_id)
      )
      execution = execution.with(
        execution_revision: 0,
        working_records: [input_record]
      )
      tx.executions.create_active(execution)
      next_root = root.with(
        agent_revision: root.agent_revision + 1,
        lifecycle_status: :active
      )
      tx.agents.save(
        root.agent_id,
        expected_revision: root.agent_revision,
        root: next_root
      )
    end
    agent.__replace_root(next_root)
    execution
  end

  def active_executions(persistence, agent_id)
    persistence.transaction do |tx|
      Array(tx.executions.list_active(agent_id))
    end
  end

  describe "durable_context snapshot" do
    it "rejects nil, non-Hash, and non-canonical nested values before admission" do
      agent = PreparingRecoverySpecAgent.create(
        agent_id: "preparing-context-invalid",
        persistence: Phronomy::Persistence::InMemory.new
      )

      expect {
        agent.invoke_async("hello", config: {durable_context: nil})
      }.to raise_error(ArgumentError, /durable_context/)
      expect {
        agent.invoke_async("hello", config: {durable_context: []})
      }.to raise_error(ArgumentError, /durable_context/)
      expect {
        agent.invoke_async(
          "hello",
          config: {durable_context: {tenant: "A"}}
        )
      }.to raise_error(ArgumentError, /canonical JSON object keys/)

      expect(active_executions(agent.persistence, agent.agent_id)).to be_empty
    end

    it "round-trips, detaches, and deep-freezes the durable context" do
      agent = PreparingRecoverySpecAgent.create(
        agent_id: "preparing-context-snapshot",
        persistence: Phronomy::Persistence::InMemory.new
      )
      original = {"tenant" => {"roles" => ["reader"]}}

      config = agent.send(
        :_snapshot_durable_context,
        durable_context: original
      )
      snapshot = config.fetch(:durable_context)
      original.fetch("tenant").fetch("roles") << "writer"

      expect(snapshot).to eq(
        "tenant" => {"roles" => ["reader"]}
      )
      expect(snapshot).to be_frozen
      expect(snapshot.fetch("tenant")).to be_frozen
      expect(snapshot.fetch("tenant").fetch("roles")).to be_frozen
    end
  end

  describe "durable admission evidence" do
    it "stores replayability and preserves an explicitly empty durable context" do
      persistence = Phronomy::Persistence::InMemory.new
      agent = PreparingRecoverySpecAgent.create(
        agent_id: "preparing-admission-evidence",
        persistence: persistence
      )
      coordinator = agent.send(:execution_coordinator)

      execution, = coordinator.send(
        :admit_execution,
        "hello",
        root: agent.agent_root,
        mode: :invoke,
        config: {durable_context: {}},
        preparation_replayable: true
      )

      expect(execution.metadata.fetch("preparation_replayable")).to be true
      ref = execution.metadata.fetch("durable_context_ref")
      expect(persistence.contents.fetch_json(ref)).to eq({})
    end
  end

  describe "replay eligibility" do
    it "is conservative for non-String, Multi-Agent, and Runtime policy dependencies" do
      agent = PreparingRecoverySpecAgent.create(
        agent_id: "preparing-replayability",
        persistence: Phronomy::Persistence::InMemory.new
      )
      coordinator = agent.send(:execution_coordinator)

      expect(
        coordinator.send(:initial_preparation_replayable?, "hello", {}, nil)
      ).to be true
      expect(
        coordinator.send(:initial_preparation_replayable?, {message: "hello"}, {}, nil)
      ).to be false
      expect(
        coordinator.send(
          :initial_preparation_replayable?,
          "hello",
          {phronomy_handoff_bindings: Object.new},
          nil
        )
      ).to be false
      expect(
        coordinator.send(
          :initial_preparation_replayable?,
          "hello",
          {},
          ->(_request) { :allow }
        )
      ).to be false

      invocation_context = Phronomy::InvocationContext.new(
        approval_policy: ->(_request) { :allow }
      )
      expect(
        coordinator.send(
          :initial_preparation_replayable?,
          "hello",
          {invocation_context: invocation_context},
          nil
        )
      ).to be false
    end
  end

  describe "load-integrated :preparing recovery" do
    it "replays the same execution_id with restored durable_context" do
      persistence = Phronomy::Persistence::InMemory.new
      agent = PreparingRecoveryHookFailureAgent.create(
        agent_id: "preparing-replay",
        persistence: persistence
      )
      execution = install_preparing_execution(
        agent,
        persistence,
        replayable: true,
        durable_context: {"tenant" => "A"}
      )

      Phronomy.reset_runtime!
      events = Queue.new
      loaded = PreparingRecoveryHookFailureAgent.load(
        "preparing-replay",
        persistence: persistence,
        on_event: ->(event) { events << event }
      )

      observed_config = Timeout.timeout(2) { PREPARING_RECOVERY_HOOK_CONFIGS.pop }
      event = Timeout.timeout(2) { events.pop }
      stored = persistence.executions.load(execution.execution_id)

      expect(loaded.agent_id).to eq("preparing-replay")
      expect(observed_config.fetch(:durable_context)).to eq("tenant" => "A")
      expect(stored.execution_id).to eq(execution.execution_id)
      expect(stored.status).to eq(:failed)
      expect(event.type).to eq(:error)
    end

    it "fails closed when replayability is false" do
      persistence = Phronomy::Persistence::InMemory.new
      agent = PreparingRecoverySpecAgent.create(
        agent_id: "preparing-not-replayable",
        persistence: persistence
      )
      install_preparing_execution(
        agent,
        persistence,
        replayable: false
      )

      Phronomy.reset_runtime!
      expect {
        PreparingRecoverySpecAgent.load(
          "preparing-not-replayable",
          persistence: persistence
        )
      }.to raise_error(
        Phronomy::ExecutionRehydrationRequiredError,
        /replay safety/
      )
    end

    it "fails closed for a legacy :preparing execution with no marker" do
      persistence = Phronomy::Persistence::InMemory.new
      agent = PreparingRecoverySpecAgent.create(
        agent_id: "preparing-legacy",
        persistence: persistence
      )
      install_preparing_execution(
        agent,
        persistence,
        replayable: false,
        include_replayable_marker: false
      )

      Phronomy.reset_runtime!
      expect {
        PreparingRecoverySpecAgent.load(
          "preparing-legacy",
          persistence: persistence
        )
      }.to raise_error(
        Phronomy::ExecutionRehydrationRequiredError,
        /replay safety/
      )
    end
  end
end
