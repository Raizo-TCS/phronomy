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

  it "keeps transient ActivationRegistry out of the Persistence contract" do
    persistence = File.read(File.join(root, "lib/phronomy/persistence.rb"))
    in_memory = File.read(File.join(root, "lib/phronomy/persistence/in_memory.rb"))
    runtime = File.read(File.join(root, "lib/phronomy/engine/runtime.rb"))

    expect(persistence).to include("workflow_states")
    expect(persistence).not_to include("activations")
    expect(in_memory).not_to include("@activations")
    expect(runtime).to include("@agent_activations")
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
      .split("def prepare_next_llm_call", 2)
      .fetch(1)
      .split("def prepare(", 2)
      .first

    expect(followup.index("assert_local_durable_base!")).to be <
      followup.index("ContextAssembler.new")
    expect(followup.index("ContextAssembler.new")).to be <
      followup.index("tx.executions.save")
  end

  it "starts a follow-up Provider Call only after preparation succeeds" do
    builder = File.read(
      File.join(root, "lib/phronomy/agent/agent_invocation_session_builder.rb")
    )
    method_source = builder
      .split("def self.prepare_and_start_llm_call", 2)
      .fetch(1)
      .split("private_class_method :prepare_and_start_llm_call", 2)
      .first

    expect(method_source).to include("preparation.on_complete")
    expect(method_source).to match(/if error.*post_preparation_failure.*else.*start_provider_call/m)
  end

  it "keeps Workflow Runtime identity distinct from durable and application identities" do
    runner = File.read(File.join(root, "lib/phronomy/workflow_runner.rb"))
    event_loop = File.read(File.join(root, "lib/phronomy/engine/event_loop.rb"))

    expect(runner).to include("fsm_session_id")
    expect(runner).to include("graph_thread_id: execution.thread_id")
    expect(event_loop).to include("owner_fsm_session_id")
    expect(event_loop).to include("@workflow_admissions")
    expect(event_loop).not_to include("owner_session_id")
  end

  it "uses the existing Persistence::InMemory Monitor as the durable in-memory transaction owner" do
    in_memory = File.read(File.join(root, "lib/phronomy/persistence/in_memory.rb"))

    expect(in_memory.scan(/@monitor\s*=\s*Monitor\.new/).length).to eq(1)
    expect(in_memory).not_to match(/@(?:workflow|state_store).*mutex/i)
  end
end
