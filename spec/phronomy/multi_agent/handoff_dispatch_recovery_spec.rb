# frozen_string_literal: true

require "spec_helper"
require "timeout"
require_relative "../../integration/support/llm_stub"

RSpec.describe "Handoff dispatch recovery through the original Runtime" do
  let(:stores) { Phronomy::PersistenceComposition.in_memory }
  let(:effects) { [] }
  let(:lookup) do
    recorded = effects
    Class.new(Phronomy::Tool::Base) do
      tool_name "handoff_recovery_lookup"
      description "Read one case without repeating its effect"
      execution_mode :cooperative
      param :case_id, type: :string, desc: "Case identity"
      define_method(:execute) { |case_id:|
        recorded << case_id
        "case details"
      }
    end
  end
  let(:source_class) do
    selected = lookup
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "handoff-recovery-source", version: 1
      model "gpt-4o-mini"
      provider :openai
      tools(selected => nil)
    end
  end
  let(:target_class) do
    selected = lookup
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "handoff-recovery-target", version: 1
      model "gpt-4o-mini"
      provider :openai
      tools(selected => nil)
    end
  end
  let(:source) { source_class.create(persistence: stores.agent) }
  let(:target) { target_class.create(persistence: stores.agent) }
  let(:edge) { Phronomy::MultiAgent::Handoff.new(source_agent: source, target_agent: target) }
  let(:runner) do
    Phronomy::MultiAgent::HandoffRunner.new(main_agent: source,
      persistence: stores.multi_agent, handoffs: [edge])
  end

  before do
    RubyLLM.configure do |configuration|
      configuration.openai_protocol = :chat_completions
      configuration.openai_api_key = "test"
    end
    @runtime = Phronomy::Runtime.instance
    @target_starts = []
    allow(target).to receive(:start_reserved_async).and_wrap_original do |original, **options|
      @target_starts << options.fetch(:reservation).execution_id
      original.call(**options)
    end
  end

  after do
    @gates&.each { |gate| gate.fetch(:release) << true }
    @runtime.shutdown(timeout: 0.03, cancel_grace: 0.2)
    LLMStub.deactivate
  end

  def result_of(task) = task.wait_result(timeout: 8)

  def configure_responses(ending)
    responses = [LLMStub.tool_call_response("handoff_recovery_lookup", {case_id: "case-42"})]
    if ending == :transfer
      binding = Phronomy::MultiAgent::HandoffCapabilityFactory.build(edge)
      responses << LLMStub.tool_call_response(binding.tool_name, {responsibility: "Finish case-42"})
    end
    responses << "case-42 completed"
    @recorder = LLMStub.activate(responses: responses)
  end

  def configure_dispatch_fault(kind:, mode:, agent: source)
    @fault = {armed: true, readback: false, writes: 0}
    allow_any_instance_of(Phronomy::Agent::ExecutionChange).to receive(:perform).and_wrap_original do |original|
      change = original.receiver
      updated = change.instance_variable_get(:@updated)
      selected = change.agent_id == agent.agent_id && change.kind == :dispatch &&
        updated&.phase == ((kind == :tool) ? :dispatching_tools : :calling_llm)
      Thread.current[:handoff_dispatch_application_fault] = selected
      original.call
    ensure
      Thread.current[:handoff_dispatch_application_fault] = nil
    end
    allow(stores.agent.coordinator).to receive(:atomic).and_wrap_original do |original, *args, &transaction|
      selected = Thread.current[:handoff_dispatch_application_fault]
      if selected && @fault[:readback]
        @fault[:readback] = false
        raise IOError, "Handoff dispatch immediate readback unavailable"
      end
      next original.call(*args, &transaction) unless selected && @fault[:armed]
      @fault[:armed] = false
      @fault[:writes] += 1
      if mode == :pre
        original.call(*args) do |scope|
          transaction.call(scope)
          @fault[:readback] = true
          raise IOError, "Handoff dispatch rolled back and response lost"
        end
      else
        original.call(*args, &transaction)
        @fault[:readback] = true
        raise IOError, "Handoff dispatch committed and response lost"
      end
    end
  end

  def start_recovery(kind: :provider, mode: :post, ending: :direct)
    configure_responses(ending)
    configure_dispatch_fault(kind: kind, mode: mode)
    expect { Timeout.timeout(8) { runner.invoke("case-42") } }
      .to raise_error(Phronomy::Agent::DispatchRecoveryError) do |failure|
        @original_error, @recovery = failure, failure.recovery
      end
    expect(@recovery.agent_id).to eq(source.agent_id)
    expect(source.pending_dispatch_recovery(execution_id: @recovery.execution_id)).to equal(@recovery)
    expect(@recorder.calls.size).to eq(1)
    expect(effects).to eq((kind == :provider) ? ["case-42"] : [])
    expect(source.__execution_environment.registry.agent_execution_admitted?(source.agent_id)).to be(true)
    expect { source.unload! }.to raise_error(Phronomy::AgentBusyError)
  end

  def owner_barrier(&action)
    completion = Phronomy::TaskResult.deferred(name: "handoff-dispatch-owner-barrier")
    receiver = Object.new
    receiver.define_singleton_method(:deliver_on_event_loop) { |_message| completion.complete(action ? action.call : true) }
    source.__execution_environment.registry.post(Struct.new(:coordinator).new(receiver), completion: completion)
    result_of(completion)
  end

  def settle_receipt(receipt)
    expect(receipt.outcome).to eq(:confirmed_post), receipt.error&.cause&.full_message
    expect(receipt.continuation_state).to eq(:resumed)
    expect(receipt).to be_resolved
    result_of(receipt.execution_task)
    runner.resume(@recovery.execution_id)
  end

  def start_target_recovery
    binding = Phronomy::MultiAgent::HandoffCapabilityFactory.build(edge)
    @recorder = LLMStub.activate(responses: [
      LLMStub.tool_call_response(binding.tool_name, {responsibility: "Finish target-42"}),
      LLMStub.tool_call_response("handoff_recovery_lookup", {case_id: "target-42"}),
      "target-42 completed"
    ])
    configure_dispatch_fault(kind: :provider, mode: :post, agent: target)
    expect { Timeout.timeout(8) { runner.invoke("target-42") } }
      .to raise_error(Phronomy::Agent::DispatchRecoveryError) do |failure|
        @original_error, @recovery = failure, failure.recovery
      end
    expect(@recovery.agent_id).to eq(target.agent_id)
    expect(target.pending_dispatch_recovery(execution_id: @recovery.execution_id)).to equal(@recovery)
    expect(effects).to eq(["target-42"])
    expect(@recorder.calls.size).to eq(2)
    @source_execution = stores.multi_agent.handoff_states.load(source.agent_id).pending_source_execution_id
  end

  [:provider, :tool].product([:pre, :post], [:direct, :transfer]).each do |kind, mode, ending|
    it "finishes the exact #{ending} chain after #{kind} #{mode} recovery without repeating business work" do
      start_recovery(kind: kind, mode: mode, ending: ending)
      original_route = stores.multi_agent.handoff_states.load(source.agent_id).to_h
      receipt = source.reconcile_dispatch(recovery: @recovery)
      if mode == :pre
        expect(receipt.outcome).to eq(:confirmed_pre)
        expect(receipt).not_to be_resolved
        expect(@recorder.calls.size).to eq(1)
        expect(stores.multi_agent.handoff_states.load(source.agent_id).to_h).to eq(original_route)
        receipt = source.retry_dispatch(recovery: @recovery)
      end
      result = settle_receipt(receipt)
      leaf_agent = (ending == :transfer) ? target : source
      expect(result).to include(status: :completed, output: "case-42 completed", agent: leaf_agent)
      expect(runner.result(@recovery.execution_id)).to include(status: :completed, output: "case-42 completed")
      expect(runner.resume(@recovery.execution_id)).to eq(result)
      expect(effects).to eq(["case-42"])
      expect(@recorder.calls.size).to eq((ending == :transfer) ? 3 : 2)
      expect(@target_starts).to eq((ending == :transfer) ? [result.fetch(:execution_id)] : [])
      expect(@fault[:writes]).to eq(1)
      expect(source.pending_dispatch_recovery(execution_id: @recovery.execution_id)).to be_nil
      expect(@original_error.recovery).to equal(@recovery)
      expect(stores.agent.observe_execution(agent_id: source.agent_id, execution_id: @recovery.execution_id).status)
        .to eq((ending == :transfer) ? :handed_off : :completed)
    end
  end

  it "keeps an unreadable save pending until authoritative reads return" do
    start_recovery
    allow(stores.agent.coordinator).to receive(:atomic).and_raise(IOError, "Handoff evidence unavailable")
    receipt = source.reconcile_dispatch(recovery: @recovery)
    expect(receipt.outcome).to eq(:unavailable)
    expect(receipt).not_to be_resolved
    expect(source.pending_dispatch_recovery(execution_id: @recovery.execution_id)).to equal(@recovery)
    expect(@recorder.calls.size).to eq(1)
    expect(effects).to eq(["case-42"])
    allow(stores.agent.coordinator).to receive(:atomic).and_call_original
    expect(settle_receipt(source.reconcile_dispatch(recovery: @recovery))).to include(output: "case-42 completed")
    expect(@recorder.calls.size).to eq(2)
    expect(effects).to eq(["case-42"])
  end

  it "refuses ordinary resumption while the exact dispatch capability is unresolved" do
    start_recovery
    expect(source).not_to receive(:resume_async)
    expect { runner.resume(@recovery.execution_id) }
      .to raise_error(Phronomy::ExecutionRehydrationRequiredError) do |error|
        expect(error.message).to include(@recovery.recovery_id, "pending_dispatch_recovery")
      end
    expect(source.pending_dispatch_recovery(execution_id: @recovery.execution_id)).to equal(@recovery)
    expect(@recorder.calls.size).to eq(1)
    expect(effects).to eq(["case-42"])
  end

  [:routing, :retention].each do |changed|
    it "does not use cached post-state to continue after current #{changed} authority changes" do
      start_recovery
      coordinator = owner_barrier do
        source.__execution_environment.registry.agent_execution_state(@recovery.execution_id).coordinator
      end
      allow(coordinator).to receive(:apply_retained_dispatch_on_event_loop).and_raise(IOError, "continuation unavailable")
      first = source.reconcile_dispatch(recovery: @recovery)
      expect(first.outcome).to eq(:confirmed_post)
      expect(first.continuation_state).to eq(:pending)
      allow(coordinator).to receive(:apply_retained_dispatch_on_event_loop).and_call_original
      if changed == :routing
        routing = stores.multi_agent.handoff_states.load(source.agent_id)
        stores.multi_agent.handoff_states.save(source.agent_id, expected_revision: routing.handoff_revision,
          state: routing.with(metadata: routing.metadata.merge("replacement" => true)))
      else
        stores.agent.coordinator.atomic do |scope|
          stores.agent.release_retention(agent_id: source.agent_id, owner_key: "handoff:#{source.agent_id}", scope: scope)
        end
      end
      expect_any_instance_of(Phronomy::Agent::Persistence::ExecutionRepository).not_to receive(:save)
      receipt = source.reconcile_dispatch(recovery: @recovery)
      expect(receipt.outcome).to eq(:confirmed_post)
      expect(receipt.continuation_state).to eq(:pending)
      expect(receipt).not_to be_resolved
      expect(receipt.error.cause).to be_a(Phronomy::Persistence::StateConflictError)
      expect(source.pending_dispatch_recovery(execution_id: @recovery.execution_id)).to equal(@recovery)
      expect(@recorder.calls.size).to eq(1)
      expect(effects).to eq(["case-42"])
    end
  end

  it "does not overwrite cancellation requested after a confirmed pre-state" do
    start_recovery(mode: :pre)
    expect(source.reconcile_dispatch(recovery: @recovery).outcome).to eq(:confirmed_pre)
    runner.cancel(@recovery.execution_id)
    receipt = source.retry_dispatch(recovery: @recovery)
    expect(receipt).not_to be_resolved
    expect(stores.agent.cancellation_requested?(agent_id: source.agent_id, execution_id: @recovery.execution_id)).to be(true)
    expect(@recorder.calls.size).to eq(1)
    expect(effects).to eq(["case-42"])
  end

  it "keeps one physical read when one recovery observer cancels" do
    start_recovery(ending: :transfer)
    gate = {entered: Queue.new, release: Queue.new}
    (@gates ||= []) << gate
    reads = 0
    allow(stores.agent.coordinator).to receive(:atomic).and_wrap_original do |original, *args, &transaction|
      reads += 1
      if reads == 1
        gate.fetch(:entered) << true
        gate.fetch(:release).pop
      end
      original.call(*args, &transaction)
    end
    first = source.reconcile_dispatch_async(recovery: @recovery)
    Timeout.timeout(8) { gate.fetch(:entered).pop }
    second = source.reconcile_dispatch_async(recovery: @recovery)
    first.cancel!
    owner_barrier
    expect(second).not_to be_done
    expect(reads).to eq(1)
    expect(@recorder.calls.size).to eq(1)
    gate.fetch(:release) << true
    receipt = result_of(second)
    expect { result_of(first) }.to raise_error(Phronomy::CancellationError)
    expect(settle_receipt(receipt)).to include(status: :completed, agent: target)
    expect(@target_starts.size).to eq(1)
    expect(@recorder.calls.size).to eq(3)
    expect(effects).to eq(["case-42"])
  end

  it "redelivers the captured continuation after notification refusal without repeating preparation" do
    start_recovery(ending: :transfer)
    coordinator = owner_barrier do
      source.__execution_environment.registry.agent_execution_state(@recovery.execution_id).coordinator
    end
    calls = 0
    allow(coordinator).to receive(:apply_retained_dispatch_on_event_loop).and_wrap_original do |original, *args|
      calls += 1
      raise IOError, "continuation notification rejected" if calls == 1
      original.call(*args)
    end
    first = source.reconcile_dispatch(recovery: @recovery)
    expect(first.outcome).to eq(:confirmed_post)
    expect(first).not_to be_resolved
    expect(first.continuation_state).to eq(:pending)
    expect(@recorder.calls.size).to eq(1)
    expect(settle_receipt(source.reconcile_dispatch(recovery: @recovery))).to include(agent: target)
    expect(calls).to eq(2)
    expect(@fault[:writes]).to eq(1)
    expect(@target_starts.size).to eq(1)
    expect(effects).to eq(["case-42"])
    expect(@recorder.calls.size).to eq(3)
  end

  it "recovers the transferred Target's subsequent dispatch without admitting that Target again" do
    start_target_recovery
    receipt = target.reconcile_dispatch(recovery: @recovery)
    expect(receipt).to be_resolved
    expect(result_of(receipt.execution_task)).to include(output: "target-42 completed")
    result = runner.resume(@source_execution)
    expect(result).to include(status: :completed, agent: target, execution_id: @recovery.execution_id)
    expect(runner.resume(@source_execution)).to eq(result)
    expect(@target_starts).to eq([@recovery.execution_id])
    expect(@recorder.calls.size).to eq(3)
    expect(effects).to eq(["target-42"])
  end

  it "does not continue the transferred Target after its Source retention is lost" do
    start_target_recovery
    coordinator = owner_barrier do
      target.__execution_environment.registry.agent_execution_state(@recovery.execution_id).coordinator
    end
    allow(coordinator).to receive(:apply_retained_dispatch_on_event_loop).and_raise(IOError, "Target continuation unavailable")
    expect(target.reconcile_dispatch(recovery: @recovery).outcome).to eq(:confirmed_post)
    allow(coordinator).to receive(:apply_retained_dispatch_on_event_loop).and_call_original
    stores.agent.coordinator.atomic do |scope|
      stores.agent.release_retention(agent_id: source.agent_id, owner_key: "handoff:#{source.agent_id}", scope: scope)
    end
    receipt = target.reconcile_dispatch(recovery: @recovery)
    expect(receipt.outcome).to eq(:confirmed_post)
    expect(receipt.continuation_state).to eq(:pending)
    expect(receipt).not_to be_resolved
    expect(receipt.error.cause).to be_a(Phronomy::Persistence::StateConflictError)
    expect(@target_starts).to eq([@recovery.execution_id])
    expect(@recorder.calls.size).to eq(2)
    expect(effects).to eq(["target-42"])
  end
end
