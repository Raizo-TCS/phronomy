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
    persistence = File.read(File.join(root, "lib/phronomy/storage/backend.rb"))
    in_memory = File.read(File.join(root, "lib/phronomy/storage/backends/in_memory.rb"))
    runtime = File.read(File.join(root, "lib/phronomy/engine/runtime.rb"))
    registry = File.read(File.join(root, "lib/phronomy/agent/execution/execution_registry.rb"))

    expect(persistence).to include("workflow_states")
    expect(persistence).not_to include("activations")
    expect(in_memory).not_to include("@activations")
    expect(runtime).not_to include("@agent_activations")
    expect(runtime).not_to include("__agent_activations")
    expect(registry).to include("@agent_executions = {}")
    expect(registry).to include("def agent_execution_owner")
  end

  it "keeps Agent durable ownership and live owner lookup semantics in Base" do
    agent_entry = File.read(File.join(root, "lib/phronomy/agent/api/agent.rb"))
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
    expect(lookup).to include("ExecutionRegistry.existing_for(Phronomy::Runtime.instance)&.agent_execution_owner")
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
    coordinator = File.read(File.join(root, "lib/phronomy/agent/execution/execution_coordinator.rb"))
    %w[reconcile_terminal_error commit_coordination_wait validate_coordination_admission!].each do |method_name|
      coordinator = coordinator.sub(/^      def #{Regexp.escape(method_name)}(?=\(|\s).*?(?=^      def |\z)/m, "")
    end
    worker = File.read(File.join(root, "lib/phronomy/agent/execution/dispatch_preparation.rb"))
    reconciliation = worker.split("def reconcile_preparation", 2).fetch(1).split(/^      def /, 2).first
    without_reconciliation = worker.sub(/^      def reconcile_preparation.*?(?=^      def )/m, "")
    expect(reconciliation).to include("@persistence.executions.load")
    [coordinator, without_reconciliation].each do |source|
      expect(source).not_to match(/(?:tx|persistence)\.agents\.load/)
      expect(source).not_to match(/(?:tx|persistence)\.executions\.load/)
      expect(source).not_to match(/(?:tx|persistence)\.journals\.read/)
      expect(source).not_to include("persistence.activations")
    end
  end

  it "guards the durable Agent watermark before fixing a follow-up Manifest" do
    worker = File.read(File.join(root, "lib/phronomy/agent/execution/dispatch_preparation.rb"))
    encoding = worker.split("def encode_provider_records", 2).fetch(1).split(/^      def /, 2).first
    commit = worker.split("def commit_provider_preparation", 2).fetch(1).split(/^      def /, 2).first
    expect(encoding.index("assert_local_durable_base!")).to be < encoding.index("RuntimeRecordEncoder.encode")
    expect(commit.index("assert_local_durable_base!")).to be < commit.index("assembler.finalize")
    expect(commit.index("assembler.finalize")).to be < commit.index("tx.executions.save")
  end

  it "starts a follow-up Provider Call only after EventLoop validates and applies preparation" do
    coordinator = File.read(
      File.join(root, "lib/phronomy/agent/execution/execution_coordinator.rb")
    )
    apply = coordinator
      .split("def apply_provider_dispatch_preparation_on_event_loop", 2)
      .fetch(1)
      .split("def apply_confirmed_tool_dispatch_preparation_on_event_loop", 2)
      .first

    expect(apply.index("authoritative_state_for_operation")).to be <
      apply.index("replace_agent_execution")
    expect(apply.index("replace_agent_execution")).to be <
      apply.index("start_prepared_provider_call")
  end

  it "keeps durable worker paths free of direct Phronomy live-state mutation" do
    coordinator = File.read(
      File.join(root, "lib/phronomy/agent/execution/execution_coordinator.rb")
    )
    worker_methods = %w[
      perform_initial_preparation
      perform_resume_commit
      compute_terminal
      commit_suspended
      commit_completed
      commit_failed_outcome
    ]

    bodies = worker_methods.map do |name|
      coordinator.split("def #{name}", 2).fetch(1).split(/^      def /, 2).first
    end
    bodies << File.read(File.join(root, "lib/phronomy/agent/execution/dispatch_preparation.rb"))
    bodies.each do |body|
      expect(body).not_to include("__replace_root")
      expect(body).not_to include("_append_journal_records")
      expect(body).not_to include("replace_agent_execution")
      expect(body).not_to include("acknowledge_runtime_snapshot")
    end
  end

  it "keeps causal-barrier reconciliation Persistence reads off EventLoop apply paths" do
    coordinator = File.read(
      File.join(root, "lib/phronomy/agent/execution/execution_coordinator.rb")
    )
    worker = File.read(File.join(root, "lib/phronomy/agent/execution/dispatch_preparation.rb"))
    provider_worker = worker
      .split("def reconcile_provider", 2)
      .fetch(1)
      .split(/^      def /, 2)
      .first
    tool_worker = worker
      .split("def reconcile_tools", 2)
      .fetch(1)
      .split(/^      def /, 2)
      .first
    provider_apply = coordinator
      .split("def apply_provider_dispatch_preparation_reconciliation_on_event_loop", 2)
      .fetch(1)
      .split(/^      def /, 2)
      .first
    tool_apply = coordinator
      .split("def apply_tool_dispatch_preparation_reconciliation_on_event_loop", 2)
      .fetch(1)
      .split(/^      def /, 2)
      .first

    expect(provider_worker).to include("reconcile_preparation")
    expect(tool_worker).to include("reconcile_preparation")
    expect(provider_apply).not_to include("executions.load")
    expect(tool_apply).not_to include("executions.load")
    expect(provider_apply).not_to include("materialize_projection")
    expect(tool_apply).not_to include("materialize_projection")
  end

  it "keeps Workflow admission ownership, FSMSession routing, and terminal persistence distinct" do
    runner = File.read(File.join(root, "lib/phronomy/workflow/execution/workflow_runner.rb"))
    registry = File.read(File.join(root, "lib/phronomy/workflow/execution/workflow_execution_registry.rb"))
    fsm = File.read(File.join(root, "lib/phronomy/engine/fsm_session.rb"))

    expect(runner).to include("workflow_instance_id")
    expect(runner).to include("owner_token: Object.new.freeze")
    expect(runner).to include("bind_workflow_session")
    expect(runner).not_to include("owner_fsm_session_id")
    expect(runner).not_to include("Phronomy::FSMSession.reserve_identity")
    expect(runner).not_to include("graph_thread_id:")

    expect(registry).to include("WorkflowAdmission = Data.define")
    expect(registry).to include(":owner_token, :fsm_session_id, :state")
    expect(registry).to include("%i[executing persisting_terminal recovery_required]")

    expect(fsm).to include("workflow_terminal_persistence_result")
    expect(fsm).to include("@terminal_lifecycle_state = :persisting_terminal")
    expect(fsm).to include("@terminal_lifecycle_state = :recovery_required")
    expect(fsm).to include("SecureRandom.uuid.to_s.freeze")
  end

  it "uses the existing Storage::Backends::InMemory Monitor as the durable in-memory transaction owner" do
    in_memory = File.read(File.join(root, "lib/phronomy/storage/backends/in_memory.rb"))

    expect(in_memory.scan(/@monitor\s*=\s*Monitor\.new/).length).to eq(1)
    expect(in_memory).not_to match(/@(?:workflow|state_store).*mutex/i)
  end

  it "does not expose class-level approve or approve_async on Agent subclasses" do
    expect(Phronomy::Agent::Base).not_to respond_to(:approve)
    expect(Phronomy::Agent::Base).not_to respond_to(:approve_async)
  end

  it "keeps durable-transition atomicity separate from F1 commit-outcome certainty" do
    persistence = File.read(File.join(root, "lib/phronomy/storage/backend.rb"))

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
    persistence = File.read(File.join(root, "lib/phronomy/storage/backend.rb"))

    expect(persistence).to include(
      "compare-and-swap conflict detection"
    )
    expect(persistence).to match(
      /does not\s+#\s+mean cross-process Workflow admission or distributed locking/m
    )
  end
end
