# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Unified Persistence architecture regression guards" do
  let(:root) { File.expand_path("../..", __dir__) }

  it "keeps StateStore and state_store out of production lib" do
    sources = Dir.glob(File.join(root, "lib/**/*.rb")).map { |path|
      [path, File.read(path)]
    }

    offenders = sources.select { |_path, source|
      source.include?("StateStore") || source.include?("state_store")
    }.map(&:first)

    expect(offenders).to be_empty
  end

  it "keeps removed StateStore APIs out of active integration support" do
    sources = Dir.glob(File.join(root, "spec/integration/**/*.rb")).map { |path|
      [path, File.read(path)]
    }

    offenders = sources.select { |_path, source|
      source.include?("Phronomy::StateStore") ||
        source.include?("default_state_store") ||
        source.match?(/\bstate_store:/)
    }.map(&:first)

    expect(offenders).to be_empty
  end

  it "keeps transient Agent execution state out of the Persistence contract" do
    persistence = File.read(File.join(root, "lib/phronomy/persistence.rb"))
    in_memory = File.read(File.join(root, "lib/phronomy/persistence/in_memory.rb"))
    runtime = File.read(File.join(root, "lib/phronomy/engine/runtime.rb"))
    event_loop = File.read(File.join(root, "lib/phronomy/engine/event_loop.rb"))

    expect(persistence).to include("workflow_states")
    expect(persistence).not_to include("activations")
    expect(in_memory).not_to include("@activations")
    expect(runtime).not_to include("@agent_activations")
    expect(runtime).not_to include("__agent_activations")
    expect(event_loop).to include("@agent_executions = {}")
    expect(event_loop).to include("def agent_execution_owner")
  end

  it "keeps Agent durable ownership and live owner lookup semantics in Base" do
    agent_entry = File.read(File.join(root, "lib/phronomy/agent.rb"))
    base = File.read(File.join(root, "lib/phronomy/agent/base.rb"))
    ownership_path = File.join(
      root,
      "lib/phronomy/agent/persistence_ownership.rb"
    )

    expect(File).not_to exist(ownership_path)
    expect(agent_entry).not_to include("persistence_ownership")
    expect(agent_entry).not_to include("PersistenceOwnership")

    class_api = base
      .split("class << self", 2)
      .fetch(1)
      .split("attr_reader :agent_id, :persistence", 2)
      .first
    lookup = class_api
      .split("def live_for_execution", 2)
      .fetch(1)
      .split("\n        end\n      end\n", 2)
      .first

    expect(class_api).to include("def live_for_execution")
    expect(class_api).not_to match(/\bdef approve(?:_async)?\b/)
    expect(lookup).to include("Phronomy::Runtime.instance.__agent_execution_owner")
    expect(lookup).not_to include("persistence.executions.load")
    expect(lookup).not_to include("persistence.agents.load")
    expect(base).to include("records: _journal_records_snapshot")

    add_knowledge = base
      .split("def add_knowledge", 2)
      .fetch(1)
      .split("def reset_context!", 2)
      .first
    mutate_context = base
      .split("def mutate_context!", 2)
      .fetch(1)
      .split("def yield_context_revision", 2)
      .first
    expect(add_knowledge).not_to include("agents.load")
    expect(mutate_context).not_to include("agents.load")
  end

  it "does not reload mutable Agent root or execution in ExecutionCoordinator" do
    coordinator = File.read(
      File.join(root, "lib/phronomy/agent/execution_coordinator.rb")
    )

    expect(coordinator).not_to match(/(?:tx|persistence)\.agents\.load/)
    expect(coordinator).not_to match(/(?:tx|persistence)\.executions\.load/)
    expect(coordinator).not_to include("persistence.activations")
  end

  it "guards the durable Agent watermark before fixing a follow-up Manifest" do
    coordinator = File.read(
      File.join(root, "lib/phronomy/agent/execution_coordinator.rb")
    )
    followup = coordinator
      .split("def perform_followup_preparation", 2)
      .fetch(1)
      .split("def apply_followup_preparation_on_event_loop", 2)
      .first

    expect(followup.index("assert_local_durable_base!")).to be <
      followup.index("ContextAssembler.new")
    expect(followup.index("ContextAssembler.new")).to be <
      followup.index("tx.executions.save")
  end

  it "starts a follow-up Provider Call only after EventLoop validates and applies preparation" do
    coordinator = File.read(
      File.join(root, "lib/phronomy/agent/execution_coordinator.rb")
    )
    apply = coordinator
      .split("def apply_followup_preparation_on_event_loop", 2)
      .fetch(1)
      .split("def begin_resume_on_event_loop", 2)
      .first

    expect(apply.index("authoritative_state_for_operation")).to be <
      apply.index("replace_agent_execution")
    expect(apply.index("replace_agent_execution")).to be <
      apply.index("start_prepared_provider_call")
  end

  it "keeps durable worker paths free of direct Phronomy live-state mutation" do
    coordinator = File.read(
      File.join(root, "lib/phronomy/agent/execution_coordinator.rb")
    )
    worker_methods = %w[
      perform_initial_preparation
      perform_followup_preparation
      perform_resume_commit
      compute_terminal
      commit_suspended
      commit_completed
      commit_failed_outcome
    ]

    worker_methods.each do |name|
      body = coordinator.split("def #{name}", 2).fetch(1).split(/^      def /, 2).first
      expect(body).not_to include("__replace_root")
      expect(body).not_to include("_append_journal_records")
      expect(body).not_to include("replace_agent_execution")
      expect(body).not_to include("acknowledge_runtime_snapshot")
    end
  end

  it "keeps Workflow Runtime identity distinct while deferring admission-owner separation to ACS-13" do
    runner = File.read(File.join(root, "lib/phronomy/workflow_runner.rb"))
    event_loop = File.read(File.join(root, "lib/phronomy/engine/event_loop.rb"))
    fsm = File.read(File.join(root, "lib/phronomy/engine/fsm_session.rb"))

    expect(runner).to include("workflow_instance_id")
    expect(runner).to include("fsm_session_id")
    expect(runner).to include("Phronomy::FSMSession.reserve_identity")
    expect(runner).to include("identity_reservation:")
    expect(runner).not_to include("graph_thread_id:")
    expect(event_loop).to include("owner_fsm_session_id")
    expect(event_loop).to include("@workflow_admissions")
    expect(event_loop).not_to include("owner_session_id")
    expect(fsm).to include("SecureRandom.uuid.to_s.freeze")
  end

  it "uses the existing Persistence::InMemory Monitor as the durable in-memory transaction owner" do
    in_memory = File.read(File.join(root, "lib/phronomy/persistence/in_memory.rb"))

    expect(in_memory.scan(/@monitor\s*=\s*Monitor\.new/).length).to eq(1)
    expect(in_memory).not_to match(/@(?:workflow|state_store).*mutex/i)
  end

  it "does not expose class-level approve or approve_async on Agent subclasses" do
    expect(Phronomy::Agent::Base).not_to respond_to(:approve)
    expect(Phronomy::Agent::Base).not_to respond_to(:approve_async)
  end

  it "keeps durable-transition atomicity separate from F1 commit-outcome certainty" do
    persistence = File.read(File.join(root, "lib/phronomy/persistence.rb"))

    expect(persistence).to include(
      "all durable repositories can participate in one atomic"
    )
    expect(persistence).to include(
      "Storage failures whose commit outcome is fundamentally"
    )
    expect(persistence).to match(
      /commit outcome is fundamentally.*Phronomy does not claim.*exactly-once semantics/m
    )
  end

  it "does not equate optimistic conflict detection with distributed exclusion" do
    persistence = File.read(File.join(root, "lib/phronomy/persistence.rb"))

    expect(persistence).to include(
      "compare-and-swap conflict detection"
    )
    expect(persistence).to match(
      /does not\s+#\s+mean cross-process Workflow admission or distributed locking/m
    )
  end
end
