# frozen_string_literal: true

require "spec_helper"
require "securerandom"
require "time"

RSpec.describe "ACS-17 causal durability" do
  class ResponseLostAfterCommitPersistence < Phronomy::Persistence
    def initialize(delegate)
      @delegate = delegate
      @lose_next_response = false
      super(backend: delegate.backend)
    end

    def capabilities = @delegate.capabilities

    def assert_agent_watermark!(**kwargs)
      @delegate.assert_agent_watermark!(**kwargs)
    end

    def lose_next_transaction_response!(skip: 0)
      @skip_count = skip
      @lose_next_response = true
      self
    end

    def transaction
      result = @delegate.transaction { |tx| yield tx }
      if @lose_next_response
        if @skip_count.to_i > 0
          @skip_count -= 1
        else
          @lose_next_response = false
          raise IOError, "simulated Persistence response loss after commit"
        end
      end
      result
    end
  end

  after do
    Phronomy.reset_runtime!
  end

  def build_agent(persistence)
    definition_id = "acs17-causal-#{SecureRandom.hex(6)}"
    klass = Class.new(Phronomy::Agent::Base) do
      agent_definition id: definition_id, version: 1
      model "local-model"
      context_window 4096
      max_output_tokens 512
    end
    klass.new(
      agent_id: "agent-#{SecureRandom.hex(6)}",
      persistence: persistence
    )
  end

  def build_base_manifest(agent, persistence)
    model_ref = persistence.contents.put_json(
      "model" => "local-model",
      "context_window" => 4096,
      "max_output_tokens" => 512,
      "cache_instructions" => false
    )
    tool_ref = persistence.contents.put_json([])
    manifest = Phronomy::Agent::LLMInputManifest.new(
      call_sequence: 1,
      call_mode: :complete,
      segments: [],
      model_config_ref: model_ref,
      tool_definitions_ref: tool_ref,
      assembly_policy_version: Phronomy::Agent::ContextAssembler::ASSEMBLY_POLICY_VERSION,
      ruby_llm_version: defined?(RubyLLM::VERSION) ? RubyLLM::VERSION : nil,
      adapter_name: Phronomy.configuration.llm_adapter.class.name
    )
    [manifest, persistence.contents.put_json(manifest.to_h)]
  end

  def establish_execution(agent, persistence)
    coordinator = agent.send(:execution_coordinator)
    execution, root = Phronomy::Agent::InitialPreparation.new(agent: agent, persistence: persistence).send(
      :admit_execution,
      "hello",
      root: agent.agent_root,
      mode: :invoke
    )
    manifest, manifest_ref = build_base_manifest(agent, persistence)
    now = Time.now.utc.iso8601(6)
    active = execution.with(
      status: :active,
      phase: :calling_llm,
      metadata: execution.metadata.merge(
        "base_manifest_ref" => manifest_ref,
        "manifest_ref" => manifest_ref,
        "manifest_refs" => [manifest_ref],
        Phronomy::Agent::ExecutionMetadata::PENDING_LLM_ID_KEY => "llm-1",
        Phronomy::Agent::ExecutionMetadata::PENDING_LLM_STARTED_AT_KEY => now
      )
    )
    persistence.executions.save(
      execution.execution_id,
      expected_revision: execution.execution_revision,
      execution: active
    )
    [coordinator, active, root, manifest, manifest_ref]
  end

  def dispatch_preparation(agent)
    Phronomy::Agent::DispatchPreparation.new(agent: agent, persistence: agent.persistence)
  end

  def provider_outcome
    Phronomy::Agent::ProviderCallOutcome.new(
      role: :assistant,
      content: nil,
      tool_calls: [
        {
          "id" => "tool-call-1",
          "name" => "lookup",
          "arguments" => {"query" => "value"}
        }
      ],
      usage: {},
      metadata: {}
    )
  end

  def provider_runtime_snapshot(manifest_ref)
    {
      llm_results: [
        {
          llm_call_id: "llm-1",
          response: provider_outcome,
          error: nil,
          streaming: false,
          manifest_ref: manifest_ref,
          started_at: Time.now.utc.iso8601(6)
        }.freeze
      ].freeze,
      runtime_events: [].freeze,
      active_call: nil
    }.freeze
  end

  def tool_batch_snapshot
    [
      {
        "tool_invocation_id" => "tool-invocation-1",
        "llm_call_id" => "llm-1",
        "tool_call_id" => "tool-call-1",
        "tool_name" => "lookup",
        "raw_arguments" => {"query" => "value"},
        "arguments" => {"query" => "value"},
        "status" => "authorized"
      }.freeze
    ].freeze
  end

  def tool_preparation_operation(coordinator, execution, root, manifest_ref)
    Phronomy::Agent::ExecutionCoordinator::ToolDispatchPreparationCommand.new(
      execution_id: execution.execution_id,
      fsm_session_id: "fsm-tool",
      expected_execution_revision: execution.execution_revision,
      root: root,
      execution: execution,
      runtime_snapshot: provider_runtime_snapshot(manifest_ref),
      tool_batch_snapshot: tool_batch_snapshot
    )
  end

  def tool_result_snapshot
    event = Phronomy::Agent::StreamEvent.new(
      type: :tool_result,
      payload: {
        tool_call_id: "tool-call-1",
        tool_name: "lookup",
        tool_result: {"answer" => 42},
        tool_message: {
          "role" => "tool",
          "content" => "{\"answer\":42}",
          "tool_call_id" => "tool-call-1"
        },
        llm_call_id: "llm-1"
      }.freeze
    )
    {
      llm_results: [].freeze,
      runtime_events: [event].freeze,
      active_call: nil
    }.freeze
  end

  def provider_preparation_operation(execution, root, base_manifest)
    Phronomy::Agent::ExecutionCoordinator::ProviderDispatchPreparationCommand.new(
      execution_id: execution.execution_id,
      fsm_session_id: "fsm-provider",
      expected_execution_revision: execution.execution_revision,
      root: root,
      journal_records: [].freeze,
      execution: execution,
      base_manifest: base_manifest,
      invocation_config: {}.freeze,
      runtime_snapshot: tool_result_snapshot,
      streaming: false,
      pending_llm_call_id: "llm-2",
      pending_llm_started_at: Time.now.utc.iso8601(6)
    )
  end

  def capture_uncertain_result
    yield
    raise "expected a PreparationOutcomeUnknownError"
  rescue => error
    raise if error.message == "expected a PreparationOutcomeUnknownError"

    expect(error).to be_a(Phronomy::Agent::DispatchPreparation::OutcomeUnknownError)
    expect(error).to respond_to(:original_error)
    expect(error).to respond_to(:intended_result)
    error
  end

  it "keeps Provider and Tool preparation components visibly symmetric" do
    coordinator = Phronomy::Agent::ExecutionCoordinator
    expect(coordinator.const_defined?(:ProviderDispatchPreparationCommand, false)).to be(true)
    expect(coordinator.const_defined?(:ProviderDispatchPreparationResult, false)).to be(true)
    expect(coordinator.const_defined?(:ProviderDispatchPreparationReady, false)).to be(true)
    expect(coordinator.const_defined?(:ToolDispatchPreparationCommand, false)).to be(true)
    expect(coordinator.const_defined?(:ToolDispatchPreparationResult, false)).to be(true)
    expect(coordinator.const_defined?(:ToolDispatchPreparationReady, false)).to be(true)
    expect(coordinator.const_defined?(:ProviderDispatchPreparationReconciliationCommand, false)).to be(true)
    expect(coordinator.const_defined?(:ProviderDispatchPreparationReconciliationResult, false)).to be(true)
    expect(coordinator.const_defined?(:ProviderDispatchPreparationReconciliationReady, false)).to be(true)
    expect(coordinator.const_defined?(:ToolDispatchPreparationReconciliationCommand, false)).to be(true)
    expect(coordinator.const_defined?(:ToolDispatchPreparationReconciliationResult, false)).to be(true)
    expect(coordinator.const_defined?(:ToolDispatchPreparationReconciliationReady, false)).to be(true)
    expect(coordinator.const_defined?(:FollowupPreparationCommand, false)).to be(false)
  end

  it "makes dispatching_tools an explicit durable-preparation state" do
    transitions = Phronomy::Agent::InvocationTransitions
    expect(transitions::AUTO_STATE_SET).not_to have_key(:dispatching_tools)
    events = transitions::EXTERNAL_EVENTS
    expect(events.fetch(:tool_dispatch_prepared))
      .to include(hash_including(from: :dispatching_tools, to: :evaluating_tools))
    expect(events.fetch(:tool_setup_failed))
      .to include(hash_including(from: :dispatching_tools, to: :failed))
  end

  it "durably records Provider outcome and pending Tool continuation before Tool dispatch" do
    persistence = Phronomy::Persistence.in_memory
    agent = build_agent(persistence)
    coordinator, execution, root, _manifest, manifest_ref =
      establish_execution(agent, persistence)
    operation = tool_preparation_operation(
      coordinator,
      execution,
      root,
      manifest_ref
    )

    result = dispatch_preparation(agent).prepare_tools(operation)
    stored = persistence.executions.load(execution.execution_id)

    expect(stored.to_h).to eq(result.execution.to_h)
    expect(stored.phase).to eq(:dispatching_tools)
    expect(stored.metadata).not_to have_key(
      Phronomy::Agent::ExecutionMetadata::PENDING_LLM_ID_KEY
    )
    expect(stored.metadata).not_to have_key(
      Phronomy::Agent::ExecutionMetadata::PENDING_LLM_STARTED_AT_KEY
    )
    expect(stored.metadata.fetch(Phronomy::Agent::ExecutionMetadata::TOOL_BATCH_METADATA_KEY))
      .to eq(tool_batch_snapshot)
    expect(stored.llm_calls.map(&:llm_call_id)).to include("llm-1")
    expect(stored.working_records.map(&:kind)).to include(:assistant_message)

    descriptor = Phronomy::Agent::RecoverySupport.recovery_descriptor(stored)
    expect(descriptor.fetch(:subject)).to eq(
      type: :tool_invocation,
      tool_invocation_id: "tool-invocation-1"
    )
    expect(descriptor.fetch(:facts)).to include(
      tool_call_id: "tool-call-1",
      tool_name: "lookup",
      llm_call_id: "llm-1"
    )
  end

  it "durably records Tool outcome and next Provider continuation before Provider dispatch" do
    persistence = Phronomy::Persistence.in_memory
    agent = build_agent(persistence)
    coordinator, execution, root, manifest, manifest_ref =
      establish_execution(agent, persistence)
    tool_operation = tool_preparation_operation(
      coordinator,
      execution,
      root,
      manifest_ref
    )
    tool_result = dispatch_preparation(agent).prepare_tools(tool_operation)
    provider_operation = provider_preparation_operation(
      tool_result.execution,
      root,
      manifest
    )

    result = dispatch_preparation(agent).prepare_provider(provider_operation)
    stored = persistence.executions.load(execution.execution_id)

    expect(stored.to_h).to eq(result.execution.to_h)
    expect(stored.phase).to eq(:calling_llm)
    expect(stored.metadata.fetch(Phronomy::Agent::ExecutionMetadata::PENDING_LLM_ID_KEY))
      .to eq("llm-2")
    expect(stored.metadata).not_to have_key(
      Phronomy::Agent::ExecutionMetadata::TOOL_BATCH_METADATA_KEY
    )
    expect(stored.metadata).not_to have_key(
      Phronomy::Agent::ExecutionMetadata::RECOVERY_METADATA_KEY
    )
    expect(stored.working_records.map(&:kind)).to include(:tool_result, :tool_message)
    expect(result.runtime_projection).not_to be_nil
  end

  it "reconciles Tool-dispatch preparation as committed off EventLoop when only the Persistence response is lost" do
    delegate = Phronomy::Persistence.in_memory
    persistence = ResponseLostAfterCommitPersistence.new(delegate)
    agent = build_agent(persistence)
    coordinator, execution, root, _manifest, manifest_ref =
      establish_execution(agent, persistence)
    operation = tool_preparation_operation(
      coordinator,
      execution,
      root,
      manifest_ref
    )
    persistence.lose_next_transaction_response!

    uncertainty = capture_uncertain_result do
      dispatch_preparation(agent).prepare_tools(operation)
    end
    command = Phronomy::Agent::ExecutionCoordinator::ToolDispatchPreparationReconciliationCommand.new(
      operation: operation,
      intended_result: uncertainty.intended_result,
      original_error: uncertainty.original_error
    )
    result = dispatch_preparation(agent).reconcile_tools(command)

    expect(result.disposition).to eq(:committed)
    expect(result.preparation_result.execution.to_h)
      .to eq(uncertainty.intended_result.execution.to_h)
    expect(result.preparation_result.execution.phase).to eq(:dispatching_tools)
  end

  it "reconciles Provider-dispatch preparation as committed off EventLoop when only the Persistence response is lost" do
    delegate = Phronomy::Persistence.in_memory
    persistence = ResponseLostAfterCommitPersistence.new(delegate)
    agent = build_agent(persistence)
    coordinator, execution, root, manifest, manifest_ref =
      establish_execution(agent, persistence)
    tool_operation = tool_preparation_operation(
      coordinator,
      execution,
      root,
      manifest_ref
    )
    tool_result = dispatch_preparation(agent).prepare_tools(tool_operation)
    operation = provider_preparation_operation(
      tool_result.execution,
      root,
      manifest
    )
    # skip: 1 because Provider preparation uses two transactions;
    # the first encodes records and the second (guarded) commits the execution save.
    persistence.lose_next_transaction_response!(skip: 1)

    uncertainty = capture_uncertain_result do
      dispatch_preparation(agent).prepare_provider(operation)
    end
    command = Phronomy::Agent::ExecutionCoordinator::ProviderDispatchPreparationReconciliationCommand.new(
      operation: operation,
      intended_result: uncertainty.intended_result,
      original_error: uncertainty.original_error
    )
    result = dispatch_preparation(agent).reconcile_provider(command)

    expect(result.disposition).to eq(:committed)
    expect(result.preparation_result.execution.to_h)
      .to eq(uncertainty.intended_result.execution.to_h)
    expect(result.preparation_result.execution.phase).to eq(:calling_llm)
    expect(result.preparation_result.runtime_projection).not_to be_nil
  end

  it "classifies an unchanged durable Tool pre-state as not committed" do
    persistence = Phronomy::Persistence.in_memory
    agent = build_agent(persistence)
    coordinator, execution, root, _manifest, manifest_ref =
      establish_execution(agent, persistence)
    operation = tool_preparation_operation(
      coordinator,
      execution,
      root,
      manifest_ref
    )
    intended = Phronomy::Agent::ExecutionCoordinator::ToolDispatchPreparationResult.new(
      execution: execution.with(phase: :dispatching_tools)
    )
    command = Phronomy::Agent::ExecutionCoordinator::ToolDispatchPreparationReconciliationCommand.new(
      operation: operation,
      intended_result: intended,
      original_error: IOError.new("simulated uncertain Tool preparation")
    )

    result = dispatch_preparation(agent).reconcile_tools(command)

    expect(result.disposition).to eq(:not_committed)
    expect(result.preparation_result).to be_nil
  end

  it "classifies an unchanged durable Provider pre-state as not committed" do
    persistence = Phronomy::Persistence.in_memory
    agent = build_agent(persistence)
    _, execution, root, manifest, _manifest_ref =
      establish_execution(agent, persistence)
    operation = provider_preparation_operation(execution, root, manifest)
    intended = Phronomy::Agent::ExecutionCoordinator::ProviderDispatchPreparationResult.new(
      execution: execution.with(phase: :calling_llm),
      runtime_projection: nil,
      error: nil
    )
    command = Phronomy::Agent::ExecutionCoordinator::ProviderDispatchPreparationReconciliationCommand.new(
      operation: operation,
      intended_result: intended,
      original_error: IOError.new("simulated uncertain Provider preparation")
    )

    result = dispatch_preparation(agent).reconcile_provider(command)

    expect(result.disposition).to eq(:not_committed)
    expect(result.preparation_result).to be_nil
  end

  it "classifies a third durable state as conflict and does not manufacture a dispatch result" do
    persistence = Phronomy::Persistence.in_memory
    agent = build_agent(persistence)
    coordinator, execution, root, _manifest, manifest_ref =
      establish_execution(agent, persistence)
    operation = tool_preparation_operation(
      coordinator,
      execution,
      root,
      manifest_ref
    )
    intended = Phronomy::Agent::ExecutionCoordinator::ToolDispatchPreparationResult.new(
      execution: execution.with(phase: :dispatching_tools)
    )
    conflicting = execution.with(
      phase: :calling_llm,
      metadata: execution.metadata.merge("acs17_conflict_marker" => true)
    )
    persistence.executions.save(
      execution.execution_id,
      expected_revision: execution.execution_revision,
      execution: conflicting
    )
    command = Phronomy::Agent::ExecutionCoordinator::ToolDispatchPreparationReconciliationCommand.new(
      operation: operation,
      intended_result: intended,
      original_error: IOError.new("simulated uncertain Tool preparation")
    )

    result = dispatch_preparation(agent).reconcile_tools(command)

    expect(result.disposition).to eq(:conflict)
    expect(result.preparation_result).to be_nil
  end

  it "does not convert a known durable conflict into F1 uncertainty" do
    persistence = Phronomy::Persistence.in_memory
    agent = build_agent(persistence)
    coordinator, execution, root, _manifest, manifest_ref =
      establish_execution(agent, persistence)
    operation = tool_preparation_operation(
      coordinator,
      execution,
      root,
      manifest_ref
    )
    conflicting = execution.with(
      metadata: execution.metadata.merge("acs17_known_conflict" => true)
    )
    persistence.executions.save(
      execution.execution_id,
      expected_revision: execution.execution_revision,
      execution: conflicting
    )

    expect {
      dispatch_preparation(agent).prepare_tools(operation)
    }.to raise_error(Phronomy::Storage::ConflictError)
  end

  it "keeps physical Provider and Tool dispatch behind confirmed apply helpers only" do
    root = File.expand_path("../../..", __dir__)
    coordinator = File.read(
      File.join(root, "lib/phronomy/agent/execution/execution_coordinator.rb")
    )

    expect(coordinator.scan("start_prepared_provider_call").length).to eq(1)
    expect(coordinator.scan("start_prepared_tool_dispatch").length).to eq(1)

    provider_apply = coordinator
      .split("def apply_confirmed_provider_dispatch_preparation_on_event_loop", 2)
      .fetch(1)
      .split(/^      def /, 2)
      .first
    tool_apply = coordinator
      .split("def apply_confirmed_tool_dispatch_preparation_on_event_loop", 2)
      .fetch(1)
      .split(/^      def /, 2)
      .first

    expect(provider_apply).to include("start_prepared_provider_call")
    expect(tool_apply).to include("start_prepared_tool_dispatch")
  end

  def provider_operation_after_tools(agent, persistence)
    coordinator, execution, root, manifest, manifest_ref = establish_execution(agent, persistence)
    tools = dispatch_preparation(agent).prepare_tools(
      tool_preparation_operation(coordinator, execution, root, manifest_ref)
    )
    provider_preparation_operation(tools.execution, root, manifest)
  end

  def bind_observed_policy(agent, &observe)
    policy = Class.new(Phronomy::Agent::ContextPolicy) do
      define_method(:call) do |input|
        observe.call
        Phronomy::Agent::ContextPolicies::Default.instance.call(input)
      end
    end.new
    agent.class.context_policy(policy)
  end

  it "keeps application hooks and Policy outside both preparation transactions" do
    persistence = Phronomy::Persistence.in_memory
    agent = build_agent(persistence)
    operation = provider_operation_after_tools(agent, persistence)
    events = []
    transaction_open = false
    original_root = agent.agent_root
    original_records = agent.send(:_journal_records_snapshot)
    bind_observed_policy(agent) do
      expect(transaction_open).to be(false)
      events << :policy
    end
    allow(persistence).to receive(:transaction).and_wrap_original do |original, &action|
      events << :transaction_started
      transaction_open = true
      original.call(&action)
    ensure
      transaction_open = false
      events << :transaction_finished
    end
    allow(agent).to receive(:run_before_llm_input_hooks).and_wrap_original do |original, **kwargs|
      expect(transaction_open).to be(false)
      events << :hook
      original.call(**kwargs)
    end
    allow(Phronomy::Agent::RubyLLMMaterializer).to receive(:new).and_wrap_original do |original, **kwargs|
      materializer = original.call(**kwargs)
      allow(materializer).to receive(:materialize).and_wrap_original do |materialize, **args|
        expect(transaction_open).to be(false)
        stored = persistence.executions.load(operation.execution_id)
        expect(stored.phase).to eq(:calling_llm)
        events << :materialize
        materialize.call(**args)
      end
      materializer
    end

    result = dispatch_preparation(agent).prepare_provider(operation)

    expect(events).to eq([:transaction_started, :transaction_finished, :hook, :policy,
      :transaction_started, :transaction_finished, :materialize])
    expect(result.error).to be_nil
    expect(agent.agent_root).to equal(original_root)
    expect(agent.send(:_journal_records_snapshot)).to eq(original_records)
  end

  it "does not classify response loss from the encoding transaction as an uncertain execution save" do
    persistence = ResponseLostAfterCommitPersistence.new(Phronomy::Persistence.in_memory)
    agent = build_agent(persistence)
    operation = provider_operation_after_tools(agent, persistence)
    persistence.lose_next_transaction_response!

    expect { dispatch_preparation(agent).prepare_provider(operation) }
      .to raise_error(IOError, /response loss/)
    expect(persistence.executions.load(operation.execution_id).to_h).to eq(operation.execution.to_h)
  end

  it "rechecks the durable Agent watermark after application Policy changes it" do
    persistence = Phronomy::Persistence.in_memory
    agent = build_agent(persistence)
    operation = provider_operation_after_tools(agent, persistence)
    bind_observed_policy(agent) do
      changed = operation.root.with(agent_revision: operation.root.agent_revision + 1)
      persistence.agents.save(changed.agent_id,
        expected_revision: operation.root.agent_revision, root: changed)
    end

    expect { dispatch_preparation(agent).prepare_provider(operation) }
      .to raise_error(Phronomy::Storage::ConflictError)
    expect(persistence.executions.load(operation.execution_id).to_h).to eq(operation.execution.to_h)
  end

  it "checks cancellation after application Policy and before committing the Provider preparation" do
    persistence = Phronomy::Persistence.in_memory
    agent = build_agent(persistence)
    operation = provider_operation_after_tools(agent, persistence)
    token = Phronomy::Concurrency::CancellationToken.new
    operation = operation.with(invocation_config: {cancellation_token: token}.freeze)
    bind_observed_policy(agent) { token.cancel! }

    expect { dispatch_preparation(agent).prepare_provider(operation) }
      .to raise_error(Phronomy::CancellationError)
    expect(persistence.executions.load(operation.execution_id).to_h).to eq(operation.execution.to_h)
  end

  it "returns the committed Provider execution with a post-commit materialization error" do
    persistence = Phronomy::Persistence.in_memory
    agent = build_agent(persistence)
    operation = provider_operation_after_tools(agent, persistence)
    failure = IOError.new("projection unavailable")
    allow(Phronomy::Agent::RubyLLMMaterializer).to receive(:new).and_wrap_original do |original, **kwargs|
      materializer = original.call(**kwargs)
      allow(materializer).to receive(:materialize).and_raise(failure)
      materializer
    end

    result = dispatch_preparation(agent).prepare_provider(operation)

    expect(result.error).to equal(failure)
    expect(result.runtime_projection).to be_nil
    expect(result.execution.phase).to eq(:calling_llm)
    expect(persistence.executions.load(operation.execution_id).to_h).to eq(result.execution.to_h)
  end

  it "retains a confirmed Provider result when reconciliation materialization fails" do
    persistence = Phronomy::Persistence.in_memory
    agent = build_agent(persistence)
    operation = provider_operation_after_tools(agent, persistence)
    committed = dispatch_preparation(agent).prepare_provider(operation)
    failure = IOError.new("saved projection unavailable")
    allow(Phronomy::Agent::SavedContextReader).to receive(:materialize_projection).and_raise(failure)
    command = Phronomy::Agent::DispatchPreparation::ProviderReconciliationCommand.new(
      operation: operation, intended_result: committed, original_error: IOError.new("lost response")
    )

    result = dispatch_preparation(agent).reconcile_provider(command)

    expect(result.disposition).to eq(:committed)
    expect(result.preparation_result.execution.to_h).to eq(committed.execution.to_h)
    expect(result.preparation_result.error).to equal(failure)
    expect(result.preparation_result.runtime_projection).to be_nil
  end

  it "propagates a reconciliation read failure without reporting an uncommitted preparation" do
    persistence = Phronomy::Persistence.in_memory
    agent = build_agent(persistence)
    operation = provider_operation_after_tools(agent, persistence)
    intended = Phronomy::Agent::DispatchPreparation::ProviderResult.new(
      execution: operation.execution.with(phase: :calling_llm), runtime_projection: nil, error: nil
    )
    command = Phronomy::Agent::DispatchPreparation::ProviderReconciliationCommand.new(
      operation: operation, intended_result: intended, original_error: IOError.new("lost response")
    )
    allow(persistence.executions).to receive(:load).with(operation.execution_id)
      .and_raise(IOError, "read unavailable")

    expect { dispatch_preparation(agent).reconcile_provider(command) }
      .to raise_error(IOError, "read unavailable")
  end

  it "rejects different preparation contents even when the intended revision matches" do
    persistence = Phronomy::Persistence.in_memory
    agent = build_agent(persistence)
    operation = provider_operation_after_tools(agent, persistence)
    committed = dispatch_preparation(agent).prepare_provider(operation)
    different = committed.execution.with(
      execution_revision: committed.execution.execution_revision,
      metadata: committed.execution.metadata.merge("different-content" => true)
    )
    command = Phronomy::Agent::DispatchPreparation::ProviderReconciliationCommand.new(
      operation: operation, intended_result: committed.with(execution: different),
      original_error: IOError.new("lost response")
    )

    result = dispatch_preparation(agent).reconcile_provider(command)

    expect(result.disposition).to eq(:conflict)
    expect(result.preparation_result).to be_nil
  end
end
