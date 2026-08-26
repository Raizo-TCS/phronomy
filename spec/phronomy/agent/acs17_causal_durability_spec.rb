# frozen_string_literal: true

require "spec_helper"
require "securerandom"
require "time"

RSpec.describe "ACS-17 causal durability" do
  class ResponseLostAfterCommitPersistence < Phronomy::Persistence
    def initialize(delegate)
      @delegate = delegate
      @lose_next_response = false
      super(
        contents: delegate.contents,
        agents: delegate.agents,
        journals: delegate.journals,
        executions: delegate.executions,
        workflow_states: delegate.workflow_states
      )
    end

    def capabilities = @delegate.capabilities

    def assert_agent_watermark!(**kwargs)
      @delegate.assert_agent_watermark!(**kwargs)
    end

    def lose_next_transaction_response!
      @lose_next_response = true
      self
    end

    def transaction
      result = @delegate.transaction { |tx| yield tx }
      if @lose_next_response
        @lose_next_response = false
        raise IOError, "simulated Persistence response loss after commit"
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
      "cache_instructions" => false,
      "parallel_tool_execution" => !!Phronomy.configuration.parallel_tool_execution
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
    execution, root = coordinator.send(
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
        Phronomy::Agent::RecoverySupport::PENDING_LLM_ID_KEY => "llm-1",
        Phronomy::Agent::RecoverySupport::PENDING_LLM_STARTED_AT_KEY => now
      )
    )
    persistence.executions.save(
      execution.execution_id,
      expected_revision: execution.execution_revision,
      execution: active
    )
    [coordinator, active, root, manifest, manifest_ref]
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

    expect(error.class.name).to end_with("PreparationOutcomeUnknownError")
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
    expect(coordinator.const_defined?(:FollowupPreparationCommand, false)).to be(false)
  end

  it "makes dispatching_tools an explicit durable-preparation state" do
    builder = Phronomy::Agent::AgentInvocationSessionBuilder
    expect(builder::AUTO_STATE_SET).not_to have_key(:dispatching_tools)
    events = builder.send(:external_events)
    expect(events.fetch(:tool_dispatch_prepared))
      .to include(hash_including(from: :dispatching_tools, to: :evaluating_tools))
    expect(events.fetch(:tool_setup_failed))
      .to include(hash_including(from: :dispatching_tools, to: :failed))
  end

  it "durably records Provider outcome and pending Tool continuation before Tool dispatch" do
    persistence = Phronomy::Persistence::InMemory.new
    agent = build_agent(persistence)
    coordinator, execution, root, _manifest, manifest_ref =
      establish_execution(agent, persistence)
    operation = tool_preparation_operation(
      coordinator,
      execution,
      root,
      manifest_ref
    )

    result = coordinator.send(:perform_tool_dispatch_preparation, operation)
    stored = persistence.executions.load(execution.execution_id)

    expect(stored.to_h).to eq(result.execution.to_h)
    expect(stored.phase).to eq(:dispatching_tools)
    expect(stored.metadata).not_to have_key(
      Phronomy::Agent::RecoverySupport::PENDING_LLM_ID_KEY
    )
    expect(stored.metadata).not_to have_key(
      Phronomy::Agent::RecoverySupport::PENDING_LLM_STARTED_AT_KEY
    )
    expect(stored.metadata.fetch(Phronomy::Agent::RecoverySupport::TOOL_BATCH_METADATA_KEY))
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
    persistence = Phronomy::Persistence::InMemory.new
    agent = build_agent(persistence)
    coordinator, execution, root, manifest, manifest_ref =
      establish_execution(agent, persistence)
    tool_operation = tool_preparation_operation(
      coordinator,
      execution,
      root,
      manifest_ref
    )
    tool_result = coordinator.send(
      :perform_tool_dispatch_preparation,
      tool_operation
    )
    provider_operation = provider_preparation_operation(
      tool_result.execution,
      root,
      manifest
    )

    result = coordinator.send(
      :perform_provider_dispatch_preparation,
      provider_operation
    )
    stored = persistence.executions.load(execution.execution_id)

    expect(stored.to_h).to eq(result.execution.to_h)
    expect(stored.phase).to eq(:calling_llm)
    expect(stored.metadata.fetch(Phronomy::Agent::RecoverySupport::PENDING_LLM_ID_KEY))
      .to eq("llm-2")
    expect(stored.metadata).not_to have_key(
      Phronomy::Agent::RecoverySupport::TOOL_BATCH_METADATA_KEY
    )
    expect(stored.metadata).not_to have_key(
      Phronomy::Agent::RecoverySupport::RECOVERY_METADATA_KEY
    )
    expect(stored.working_records.map(&:kind)).to include(:tool_result, :tool_message)
    expect(result.runtime_projection).not_to be_nil
  end

  it "reconciles Tool-dispatch preparation as committed when only the Persistence response is lost" do
    delegate = Phronomy::Persistence::InMemory.new
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
      coordinator.send(:perform_tool_dispatch_preparation, operation)
    end
    intended = uncertainty.intended_result.execution
    disposition, current = coordinator.send(
      :preparation_reconciliation_state,
      operation,
      intended
    )

    expect(disposition).to eq(:committed)
    expect(current.to_h).to eq(intended.to_h)
    expect(current.phase).to eq(:dispatching_tools)
  end

  it "reconciles Provider-dispatch preparation as committed when only the Persistence response is lost" do
    delegate = Phronomy::Persistence::InMemory.new
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
    tool_result = coordinator.send(
      :perform_tool_dispatch_preparation,
      tool_operation
    )
    operation = provider_preparation_operation(
      tool_result.execution,
      root,
      manifest
    )
    persistence.lose_next_transaction_response!

    uncertainty = capture_uncertain_result do
      coordinator.send(:perform_provider_dispatch_preparation, operation)
    end
    intended = uncertainty.intended_result.execution
    disposition, current = coordinator.send(
      :preparation_reconciliation_state,
      operation,
      intended
    )

    expect(disposition).to eq(:committed)
    expect(current.to_h).to eq(intended.to_h)
    expect(current.phase).to eq(:calling_llm)
    expect(current.metadata.fetch(Phronomy::Agent::RecoverySupport::PENDING_LLM_ID_KEY))
      .to eq("llm-2")
  end
end
