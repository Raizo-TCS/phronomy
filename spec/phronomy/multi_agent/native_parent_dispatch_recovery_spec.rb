# frozen_string_literal: true

require "spec_helper"
require_relative "../../integration/support/hosted_subagent"

RSpec.describe "Native parent dispatch recovery through the original Runtime" do
  include_context "a native child requiring approval"
  let(:effects) { [] }
  let(:child_tool) do
    results = effects
    Class.new(Phronomy::Tool::Base) do
      tool_name "child_recovery_action"
      description "Records the one child action"
      param :input, type: :string, desc: "Action input"
      on_error :raise
      define_method(:execute) do |input:|
        results << input
        "child action completed"
      end
    end
  end
  let(:child_class) { IntegrationFactors.agent_class("base", tools: [child_tool]) }

  let(:parent_class) do
    worker, selected_policy = child_class, policy
    Class.new(Phronomy::MultiAgent::Orchestrator) do
      agent_definition id: "parent-result-policy-#{selected_policy}", version: 1
      model IntegrationFactors::LM_MODEL_30
      provider :openai
      tools IntegrationFactors::NoApprovalTool => nil
      subagent :worker, worker, on_error: selected_policy
    end
  end

  before do
    RubyLLM.configure do |configuration|
      configuration.openai_protocol = :chat_completions
      configuration.openai_api_key = "test"
    end
    responses = [dispatch, LLMStub.tool_call_response("child_recovery_action", {input: "once"})]
    responses << "child completed" if ending == :success
    responses << "parent completed"
    @recorder = LLMStub.activate(responses: responses)
    @runtime = Phronomy::Runtime.instance
    allow_any_instance_of(child_class).to receive(:start_reserved_async).and_wrap_original do |original, **options|
      @child_starts ||= []
      @child_starts << options.fetch(:reservation).execution_id
      @child_agent_id = original.receiver.agent_id
      @child_execution_id = options.fetch(:reservation).execution_id
      original.call(**options).tap { |task| @original_child_task ||= task }
    end
  end

  after do
    @parent_gates&.each { |waiting| waiting.fetch(:release) << true }
    @runtime.shutdown(timeout: 0.03, cancel_grace: 0.2)
  end

  def result_of(task) = task.wait_result(timeout: 8)

  let(:policy) { :raise }
  let(:ending) { :success }

  def configure_parent_dispatch_fault(kind:, mode:)
    @parent_fault = {armed: true, readback: false, attempts: 0}
    allow_any_instance_of(Phronomy::Agent::ExecutionChange).to receive(:perform).and_wrap_original do |original|
      change = original.receiver
      updated = change.instance_variable_get(:@updated)
      selected = change.agent_id == parent.agent_id && change.execution_id == root_id && change.kind == :dispatch &&
        updated&.phase == ((kind == :tool) ? :dispatching_tools : :calling_llm)
      if selected && @parent_fault[:armed] && @parent_fault[:capture_cancellation]
        stores.agent.request_cancellation(agent_id: parent.agent_id, execution_id: root_id)
      end
      Thread.current[:parent_dispatch_recovery_fault] = selected
      original.call
    ensure
      Thread.current[:parent_dispatch_recovery_fault] = nil
    end
    allow(stores.agent.coordinator).to receive(:atomic).and_wrap_original do |original, *args, &transaction|
      selected = Thread.current[:parent_dispatch_recovery_fault]
      if selected && @parent_fault[:readback]
        @parent_fault[:readback] = false
        raise IOError, "parent immediate readback unavailable"
      end
      next original.call(*args, &transaction) unless selected && @parent_fault[:armed]
      @parent_fault[:armed] = false
      @parent_fault[:attempts] += 1
      if mode == :pre
        original.call(*args) do |scope|
          transaction.call(scope)
          @parent_fault[:readback] = true
          raise IOError, "parent dispatch transaction rolled back and response lost"
        end
      else
        original.call(*args, &transaction)
        @parent_fault[:readback] = true
        raise IOError, "parent dispatch transaction committed and response lost"
      end
    end
  end

  def start_parent_recovery
    reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: root_id)
    @original = parent.start_hosted(reservation: reservation, input: "run", config: {cancellation_token: token})
    expect { result_of(@original) }.to raise_error(Phronomy::Agent::DispatchRecoveryError) do |failure|
      @original_error, @recovery = failure, failure.recovery
    end
    expect(parent.pending_dispatch_recovery(execution_id: root_id)).to equal(@recovery)
    expect(@recovery.execution_id).to eq(root_id)
    expect_parent_owner_retained
  end

  def expect_parent_owner_retained
    expect(parent.__execution_environment.registry.agent_execution_admitted?(parent.agent_id)).to be(true)
    expect { parent.unload! }.to raise_error(Phronomy::AgentBusyError)
    expect(parent_class.get(parent.agent_id)).to equal(parent)
  end

  def expect_parent_original_closed
    expect { result_of(@original) }.to raise_error { |observed| expect(observed).to equal(@original_error) }
  end

  def parent_slots
    extension = stores.agent.execution_extension(agent_id: parent.agent_id, execution_id: root_id,
      binding_key: "phronomy.subagent")
    extension.state_ref ? stores.multi_agent.contents.fetch_json(extension.state_ref).fetch("children") : []
  end

  def parent_owner_barrier(&action)
    completion = Phronomy::TaskResult.deferred(name: "parent-recovery-owner-barrier")
    receiver = Object.new
    receiver.define_singleton_method(:deliver_on_event_loop) { |_message| completion.complete(action ? action.call : true) }
    parent.__execution_environment.registry.post(Struct.new(:coordinator).new(receiver), completion: completion)
    result_of(completion)
  end

  def parent_gate
    {entered: Queue.new, release: Queue.new}.tap { |waiting| (@parent_gates ||= []) << waiting }
  end

  def before_parent_continuation(kind)
    expect(@recorder.calls.size).to eq((kind == :provider) ? 3 : 1)
    expect(effects).to eq((kind == :provider) ? ["once"] : [])
  end

  [:provider, :tool].product([:pre, :post]).each do |kind, mode|
    it "recovers #{kind} #{mode} without repeating child creation or business work" do
      configure_parent_dispatch_fault(kind: kind, mode: mode)
      start_parent_recovery
      before_parent_continuation(kind)
      expect(@parent_fault[:attempts]).to eq(1)
      expect(parent_slots.size).to eq((kind == :tool && mode == :pre) ? 0 : 1)
      receipt = parent.reconcile_dispatch(recovery: @recovery)
      if mode == :pre
        expect(receipt.outcome).to eq(:confirmed_pre)
        expect(receipt).not_to be_resolved
        expect_parent_owner_retained
        before_parent_continuation(kind)
        receipt = parent.retry_dispatch(recovery: @recovery)
      end
      expect(receipt.outcome).to eq(:confirmed_post), receipt.error&.cause&.full_message
      expect(receipt.continuation_state).to eq(:resumed)
      expect(receipt).to be_resolved
      expect(result_of(receipt.execution_task)).to include(output: "parent completed")
      expect(stores.agent.executions.load(root_id).status).to eq(:completed)
      expect(result_of(@original_child_task)).to include(status: :completed, output: "child completed")
      expect_parent_original_closed
      expect(parent.pending_dispatch_recovery(execution_id: root_id)).to be_nil
      expect(@child_starts).to eq([@child_execution_id])
      expect(parent_slots).to contain_exactly(include("execution_id" => @child_execution_id, "imported" => true))
      expect(effects).to eq(["once"])
      expect(@recorder.calls.size).to eq(4)
      expect(@parent_fault[:attempts]).to eq(1)
      child = child_class.get(@child_agent_id)
      holds = [parent, child].to_h { |agent| [agent.agent_id, stores.agent.retained_references(agent_id: agent.agent_id)] }
      expect(holds.values.map(&:size)).to eq([1, 1])
      expect(parent.unload_with_completed_child!(root_id, execution_id: @child_execution_id)).to be(true)
      expect(parent_class.get(parent.agent_id)).to be_nil
      expect(child_class.get(child.agent_id)).to be_nil
      holds.each { |id, saved| expect(stores.agent.retained_references(agent_id: id)).to eq(saved) }
    end
  end

  [:provider, :tool].product([:reconcile, :retry]).each do |kind, action|
    it "rechecks current parent holds after cached #{kind} post evidence on #{action}" do
      configure_parent_dispatch_fault(kind: kind, mode: :post)
      start_parent_recovery
      coordinator = parent_owner_barrier { parent.__execution_environment.registry.agent_execution_state(root_id).coordinator }
      allow(coordinator).to receive(:apply_retained_dispatch_on_event_loop).and_raise(IOError, "parent continuation unavailable")
      first = parent.reconcile_dispatch(recovery: @recovery)
      expect(first.outcome).to eq(:confirmed_post)
      expect(first.continuation_state).to eq(:pending)
      allow(coordinator).to receive(:apply_retained_dispatch_on_event_loop).and_call_original
      stores.agent.retain(Phronomy::Agent::Retention.new(agent_id: parent.agent_id,
        execution_id: root_id, owner_key: "another-owner"))
      expect_any_instance_of(Phronomy::Agent::Persistence::ExecutionRepository).not_to receive(:save)
      receipt = parent.public_send("#{action}_dispatch", recovery: @recovery)
      expect(receipt.outcome).to eq(:confirmed_post)
      expect(receipt.continuation_state).to eq(:pending)
      expect(receipt).not_to be_resolved
      expect(receipt.error.cause).to be_a(Phronomy::Persistence::StateConflictError)
      expect_parent_owner_retained
      expect_parent_original_closed
      before_parent_continuation(kind)
    end
  end

  [:reservation, :retention].each do |changed|
    it "blocks cached parent import evidence after the child's #{changed} changes" do
      configure_parent_dispatch_fault(kind: :provider, mode: :post)
      start_parent_recovery
      coordinator = parent_owner_barrier { parent.__execution_environment.registry.agent_execution_state(root_id).coordinator }
      allow(coordinator).to receive(:apply_retained_dispatch_on_event_loop).and_raise(IOError, "parent continuation unavailable")
      expect(parent.reconcile_dispatch(recovery: @recovery).outcome).to eq(:confirmed_post)
      allow(coordinator).to receive(:apply_retained_dispatch_on_event_loop).and_call_original
      if changed == :reservation
        saved = stores.agent.executions.load(@child_execution_id)
        reservation = saved.metadata.fetch("reservation").merge("slot" => "another-parent-slot")
        stores.agent.executions.save(@child_execution_id, expected_revision: saved.execution_revision,
          execution: saved.with(metadata: saved.metadata.merge("reservation" => reservation)))
      else
        stores.agent.coordinator.atomic do |scope|
          stores.agent.release_retention(agent_id: @child_agent_id, owner_key: "subagent:#{root_id}", scope: scope)
        end
      end
      expect_any_instance_of(Phronomy::Agent::Persistence::ExecutionRepository).not_to receive(:save)
      receipt = parent.retry_dispatch(recovery: @recovery)
      expect(receipt.outcome).to eq(:confirmed_post)
      expect(receipt.continuation_state).to eq(:pending)
      expect(receipt).not_to be_resolved
      expect(receipt.error.cause).to be_a(Phronomy::Persistence::StateConflictError)
      expect_parent_owner_retained
      before_parent_continuation(:provider)
    end
  end

  it "does not admit a new captured slot after an unrelated root takes its child identity" do
    configure_parent_dispatch_fault(kind: :tool, mode: :post)
    start_parent_recovery
    coordinator = parent_owner_barrier { parent.__execution_environment.registry.agent_execution_state(root_id).coordinator }
    allow(coordinator).to receive(:apply_retained_dispatch_on_event_loop).and_raise(IOError, "parent continuation unavailable")
    expect(parent.reconcile_dispatch(recovery: @recovery).outcome).to eq(:confirmed_post)
    allow(coordinator).to receive(:apply_retained_dispatch_on_event_loop).and_call_original
    child_class.create(agent_id: parent_slots.fetch(0).fetch("agent_id"), persistence: stores.agent)
    expect_any_instance_of(Phronomy::Agent::Persistence::ExecutionRepository).not_to receive(:save)
    receipt = parent.reconcile_dispatch(recovery: @recovery)
    expect(receipt.outcome).to eq(:confirmed_post)
    expect(receipt.continuation_state).to eq(:pending)
    expect(receipt).not_to be_resolved
    expect(receipt.error.cause).to be_a(Phronomy::Persistence::StateConflictError)
    expect_parent_owner_retained
    before_parent_continuation(:tool)
  end

  it "retains unavailable parent evidence until authoritative reads return" do
    configure_parent_dispatch_fault(kind: :tool, mode: :post)
    start_parent_recovery
    allow(stores.agent.coordinator).to receive(:atomic).and_raise(IOError, "parent evidence unavailable")
    receipt = parent.reconcile_dispatch(recovery: @recovery)
    expect(receipt.outcome).to eq(:unavailable)
    expect(receipt).not_to be_resolved
    expect_parent_owner_retained
    before_parent_continuation(:tool)
    allow(stores.agent.coordinator).to receive(:atomic).and_call_original
    receipt = parent.reconcile_dispatch(recovery: @recovery)
    expect(result_of(receipt.execution_task)).to include(output: "parent completed")
    expect(effects).to eq(["once"])
  end

  it "does not overwrite parent cancellation persisted after confirmed pre-state" do
    configure_parent_dispatch_fault(kind: :tool, mode: :pre)
    start_parent_recovery
    expect(parent.reconcile_dispatch(recovery: @recovery).outcome).to eq(:confirmed_pre)
    stores.agent.request_cancellation(agent_id: parent.agent_id, execution_id: root_id)
    receipt = parent.retry_dispatch(recovery: @recovery)
    expect(receipt.outcome).to eq(:unresolved)
    expect(receipt).not_to be_resolved
    expect(stores.agent.cancellation_requested?(agent_id: parent.agent_id, execution_id: root_id)).to be(true)
    expect(parent_slots).to be_empty
    expect_parent_owner_retained
    before_parent_continuation(:tool)
  end

  [:provider, :tool].each do |kind|
    it "honors cancellation already captured by the parent's #{kind} proof" do
      configure_parent_dispatch_fault(kind: kind, mode: :post)
      @parent_fault[:capture_cancellation] = true
      start_parent_recovery
      expect(stores.agent.cancellation_requested?(agent_id: parent.agent_id, execution_id: root_id)).to be(true)
      receipt = parent.reconcile_dispatch(recovery: @recovery)
      expect(receipt.outcome).to eq(:confirmed_post), receipt.error&.cause&.full_message
      expect { result_of(receipt.execution_task) }.to raise_error(Phronomy::CancellationError)
      expect(stores.agent.executions.load(root_id).status).to eq(:cancelled)
      before_parent_continuation(kind)
      expect_parent_original_closed
    end
  end

  it "keeps the physical read and parent owner when one observer is cancelled" do
    configure_parent_dispatch_fault(kind: :tool, mode: :post)
    start_parent_recovery
    waiting, reads = parent_gate, 0
    allow(stores.agent.coordinator).to receive(:atomic).and_wrap_original do |original, *args, &transaction|
      reads += 1
      if reads == 1
        waiting.fetch(:entered) << true
        waiting.fetch(:release).pop
      end
      original.call(*args, &transaction)
    end
    first = parent.reconcile_dispatch_async(recovery: @recovery)
    Timeout.timeout(8) { waiting.fetch(:entered).pop }
    second = parent.reconcile_dispatch_async(recovery: @recovery)
    first.cancel!
    parent_owner_barrier
    expect(second).not_to be_done
    expect_parent_owner_retained
    before_parent_continuation(:tool)
    expect(reads).to eq(1)
    waiting.fetch(:release) << true
    receipt = result_of(second)
    expect { result_of(first) }.to raise_error(Phronomy::CancellationError)
    expect(result_of(receipt.execution_task)).to include(output: "parent completed")
    expect(@child_starts).to eq([@child_execution_id])
    expect(effects).to eq(["once"])
  end
end
