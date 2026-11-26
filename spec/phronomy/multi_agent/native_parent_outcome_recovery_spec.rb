# frozen_string_literal: true

require "spec_helper"
require_relative "../../integration/support/hosted_subagent"

RSpec.describe "Native parent outcome and approval recovery through the original Runtime" do
  include_context "a native child requiring approval"
  let(:effects) { [] }
  let(:resolution_events) { Queue.new }
  let(:options) do
    {persistence: stores.agent, coordination_store: stores.multi_agent,
     on_event: ->(event) {
       events << event.payload.fetch(:request) if event.type == :approval_required
       resolution_events << event.payload if event.type == :recovery_resolution_required
     }}
  end
  let(:approval_tool) do
    recorded = effects
    Class.new(Phronomy::Tool::Base) do
      tool_name "approval_required_tool"
      description "Records an approved protected operation"
      param :query, type: :string, desc: "Protected input"
      requires_approval true
      define_method(:execute) do |query:|
        recorded << query
        "approved #{query}"
      end
    end
  end
  let(:child_class) { IntegrationFactors.approval_resume_agent(approval_tool) }
  let(:parent_class) do
    worker, protected_tool = child_class, approval_tool
    Class.new(Phronomy::MultiAgent::Orchestrator) do
      agent_definition id: "native-parent-own-approval", version: 1
      model IntegrationFactors::LM_MODEL_30
      provider :openai
      tools protected_tool => nil
      subagent :worker, worker
    end
  end

  before do
    RubyLLM.configure do |configuration|
      configuration.openai_protocol = :chat_completions
      configuration.openai_api_key = "test"
    end
    @runtime = Phronomy::Runtime.instance
  end
  after { @runtime.shutdown(timeout: 0.03, cancel_grace: 0.2) }

  def lose_save(boundary:, mode:)
    @fault = {armed: true, readback: false, attempts: 0, readback_failures: 0}
    if boundary == :decision
      [:commit, :commit_retained].each do |method|
        allow_any_instance_of(Phronomy::Agent::ApprovalResumeCommit).to receive(method).and_wrap_original do |original, operation, **options|
          Thread.current[:g3h_parent_fault] = operation.execution.agent_id == parent.agent_id && operation.execution_id == root_id
          original.call(operation, **options)
        ensure
          Thread.current[:g3h_parent_fault] = nil
        end
      end
    else
      allow_any_instance_of(Phronomy::Agent::ExecutionChange).to receive(:perform).and_wrap_original do |original|
        change = original.receiver
        Thread.current[:g3h_parent_fault] = change.agent_id == parent.agent_id && change.execution_id == root_id && change.kind == :terminal
        original.call
      ensure
        Thread.current[:g3h_parent_fault] = nil
      end
    end
    allow(stores.agent.coordinator).to receive(:atomic).and_wrap_original do |original, *args, &transaction|
      selected = Thread.current[:g3h_parent_fault]
      if selected && @fault[:readback]
        @fault[:readback] = false
        @fault[:readback_failures] += 1
        raise IOError, "immediate native parent readback unavailable"
      end
      next original.call(*args, &transaction) unless selected && @fault[:armed]
      @fault[:armed] = false
      @fault[:attempts] += 1
      if mode == :pre
        original.call(*args) do |scope|
          transaction.call(scope)
          @fault[:readback] = boundary != :decision
          raise IOError, "native parent transaction rolled back and response lost"
        end
      else
        original.call(*args, &transaction)
        @fault[:readback] = boundary != :decision
        raise IOError, "native parent transaction committed and response lost"
      end
    end
  end

  def result_of(task) = task.wait_result(timeout: 8)

  def start_parent
    reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: root_id)
    @original = parent.start_hosted(reservation: reservation, input: "run", config: {cancellation_token: token})
  end

  def start_outcome_recovery
    start_parent
    expect { result_of(@original) }.to raise_error(Phronomy::Agent::OutcomeRecoveryError) do |failure|
      @original_error, @recovery = failure, failure.recovery
    end
    expect(parent.pending_outcome_recovery(execution_id: root_id)).to equal(@recovery)
    expect_parent_retained
  end

  def expect_parent_retained
    expect(parent.__execution_environment.registry.agent_execution_admitted?(parent.agent_id)).to be(true)
    expect { parent.unload! }.to raise_error(Phronomy::AgentBusyError)
    expect(parent_class.get(parent.agent_id)).to equal(parent)
  end

  def expect_original_closed
    expect { result_of(@original) }.to raise_error { |observed| expect(observed).to equal(@original_error) }
  end

  def finish_outcome(mode, expected_kind)
    receipt = parent.reconcile_outcome(recovery: @recovery)
    if mode == :pre
      expect(receipt.outcome).to eq(:confirmed_pre), receipt.error&.cause&.full_message
      expect(receipt.application_state).to eq(:pending)
      expect(receipt.ownership_state).to eq(:retained)
      expect(receipt.saved_outcome).to be_nil
      expect(receipt.execution).to be_nil
      expect(receipt.approval_request).to be_nil
      expect_parent_retained
      receipt = parent.retry_outcome(recovery: @recovery)
    end
    expect(receipt.outcome).to eq(:confirmed_post), receipt.error&.cause&.full_message
    expect(receipt.application_state).to eq(:applied), receipt.error&.cause&.full_message
    expect(receipt.ownership_state).to eq(:released)
    expect(receipt.saved_outcome).to eq(expected_kind)
    expect_original_closed
    receipt
  end

  [:pre, :post].each do |mode|
    it "recovers the exact successful native final outcome after #{mode} loss" do
      @recorder = LLMStub.activate(responses: ["parent completed"])
      lose_save(boundary: :terminal, mode: mode)
      start_outcome_recovery
      receipt = finish_outcome(mode, :terminal)
      expect(receipt.execution.status).to eq(:completed)
      expect(receipt.execution.result).to eq("parent completed")
      expect(receipt.approval_request).to be_nil
      expect(parent.resume(root_id)).to include(status: :completed, output: "parent completed")
      expect(@recorder.calls.size).to eq(1)
      expect(effects).to be_empty
      expect(parent.unload!).to be(true)
    end

    it "restores the exact native own approval wait after #{mode} loss" do
      @recorder = LLMStub.activate(responses: [protected_call, "parent completed"])
      lose_save(boundary: :wait, mode: mode)
      start_outcome_recovery
      expect(events).to be_empty
      receipt = finish_outcome(mode, :approval_wait)
      request = receipt.approval_request
      expect(request.execution_id).to eq(root_id)
      expect(receipt.execution).to be_nil
      expect(events).to be_empty
      expect(stores.agent.executions.load(root_id).status).to eq(:suspended)
      expect_parent_retained
      result = result_of(parent.approve_async(root_id, approval_request_id: request.id, approved: true))
      expect(result).to include(output: "parent completed")
      expect(effects).to eq(["check"])
      expect(@recorder.calls.size).to eq(2)
      expect_original_closed
      expect(parent.unload!).to be(true)
    end

    it "restores native coordination wait without completing or replaying its child after #{mode} loss" do
      @recorder = LLMStub.activate(responses: [dispatch, protected_call, "child completed", "parent completed"])
      lose_save(boundary: :coordination_wait, mode: mode)
      start_outcome_recovery
      request = Timeout.timeout(8) { events.pop }
      receipt = finish_outcome(mode, :coordination_wait)
      expect(receipt.execution).to be_nil
      expect(receipt.approval_request).to be_nil
      expect(stores.agent.executions.load(root_id).status).to eq(:active)
      expect(parent.__execution_environment.registry.agent_execution_admitted?(parent.agent_id)).to be(false)
      expect(@recorder.calls.size).to eq(2)
      expect(effects).to be_empty
      child = child_class.get(stores.agent.execution_identity(request.execution_id).agent_id)
      child_result = result_of(child.approve_async(request.execution_id, approval_request_id: request.id, approved: true))
      expect(child_result).to include(output: "child completed")
      expect(parent.resume(root_id)).to include(status: :completed, output: "parent completed")
      expect(effects).to eq(["check"])
      expect(@recorder.calls.size).to eq(4)
      expect(parent.unload_with_completed_child!(root_id, execution_id: request.execution_id)).to be(true)
    end

    it "reconciles the native parent's own approval decision after #{mode} loss" do
      @recorder = LLMStub.activate(responses: [protected_call, "parent completed"])
      start_parent
      request = Timeout.timeout(8) { events.pop }
      lose_save(boundary: :decision, mode: mode)
      task = parent.approve_async(root_id, approval_request_id: request.id, approved: true)
      failure = recovery = nil
      expect { result_of(task) }.to raise_error(Phronomy::Agent::ApprovalRecoveryError) do |error|
        failure, recovery = error, error.recovery
      end
      expect(parent.pending_approval_recovery(execution_id: root_id)).to equal(recovery)
      expect_parent_retained
      expect(effects).to be_empty
      receipt = parent.reconcile_approval(recovery: recovery)
      expect(receipt).to be_resolved, receipt.error&.cause&.full_message
      if mode == :pre
        expect(receipt.outcome).to eq(:confirmed_pre)
        expect(receipt.continuation_state).to eq(:restored)
        expect(receipt.execution_task).to be_nil
        expect(effects).to be_empty
        expect(@recorder.calls.size).to eq(1)
        execution_task = parent.approve_async(root_id, approval_request_id: request.id, approved: true)
      else
        expect(receipt.outcome).to eq(:confirmed_post)
        expect(receipt.continuation_state).to eq(:resumed)
        execution_task = receipt.execution_task
      end
      expect(result_of(execution_task)).to include(output: "parent completed")
      expect { result_of(task) }.to raise_error { |error| expect(error).to equal(failure) }
      expect(effects).to eq(["check"])
      expect(@recorder.calls.size).to eq(2)
      expect(parent.pending_approval_recovery(execution_id: root_id)).to be_nil
      expect(parent.unload!).to be(true)
    end
  end

  def eventually
    Timeout.timeout(8) do
      loop do
        value = yield
        return value if value
        sleep 0.002
      end
    end
  end

  def start_decision_recovery(request, mode:)
    lose_save(boundary: :decision, mode: mode)
    task = parent.approve_async(root_id, approval_request_id: request.id, approved: true)
    recovery = nil
    expect { result_of(task) }.to raise_error(Phronomy::Agent::ApprovalRecoveryError) { |error| recovery = error.recovery }
    recovery
  end

  [:pre, :post].each do |mode|
    [:before_recovery, :after_recovery].each do |timing|
      it "honors own wait cancellation #{timing} after #{mode} loss without replaying old callbacks" do
        @recorder = LLMStub.activate(responses: [protected_call, "must not run"])
        lose_save(boundary: :wait, mode: mode)
        start_outcome_recovery
        token.cancel! if timing == :before_recovery
        receipt = finish_outcome(mode, :approval_wait)
        expect(receipt.approval_request.execution_id).to eq(root_id)
        token.cancel! if timing == :after_recovery
        eventually { stores.agent.executions.load(root_id).status == :cancelled }
        eventually { !parent.__execution_environment.registry.agent_execution_admitted?(parent.agent_id) }
        expect(events).to be_empty
        expect(effects).to be_empty
        expect(@recorder.calls.size).to eq(1)
        expect_original_closed
        expect(parent.unload!).to be(true)
      end
    end

    it "recovers native cancellation persisted from a suspended parent after #{mode} loss" do
      @recorder = LLMStub.activate(responses: [protected_call, "must not run"])
      start_parent
      Timeout.timeout(8) { events.pop }
      lose_save(boundary: :terminal, mode: mode)
      token.cancel!
      expect { result_of(@original) }.to raise_error(Phronomy::Agent::OutcomeRecoveryError) do |error|
        @original_error, @recovery = error, error.recovery
      end
      receipt = finish_outcome(mode, :terminal)
      expect(receipt.execution.status).to eq(:cancelled)
      expect(receipt.execution.result).to be_nil
      expect(receipt.error).to be_nil
      expect(effects).to be_empty
      expect(@recorder.calls.size).to eq(1)
      expect(parent.unload!).to be(true)
    end

    it "recovers an actual native business failure after #{mode} loss without repeating its Provider" do
      @recorder = Struct.new(:calls).new([])
      calls = @recorder.calls
      adapter = Class.new(Phronomy::LLMAdapter::Base) do
        define_method(:perform_complete) do |request, cancellation_token:|
          calls << request
          raise IOError, "native Provider business failure"
        end
      end.new
      Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
      lose_save(boundary: :terminal, mode: mode)
      start_outcome_recovery
      receipt = finish_outcome(mode, :terminal)
      expect(receipt.execution.status).to eq(:failed)
      expect(receipt.execution.error.to_s).to include("native Provider business failure")
      expect(receipt.error).to be_nil
      expect(effects).to be_empty
      expect(@recorder.calls.size).to eq(1)
      expect(parent.unload!).to be(true)
    end

    it "preserves the existing factual-resolution boundary for mixed Tool batches after #{mode} decision loss" do
      mixed = {"choices" => [{"index" => 0, "finish_reason" => "tool_calls", "message" => {
        "role" => "assistant", "content" => nil, "tool_calls" => [
          {"id" => "own-protected", "type" => "function", "function" => {"name" => "approval_required_tool", "arguments" => JSON.generate(query: "parent check")}},
          {"id" => "native-dispatch", "type" => "function", "function" => {"name" => "dispatch_to_worker", "arguments" => JSON.generate(input: "child request")}}
        ]
      }}]}
      @recorder = LLMStub.activate(responses: [mixed, protected_call, "child completed", "parent completed"])
      start_parent
      parent_request = Timeout.timeout(8) { events.pop }
      recovery = start_decision_recovery(parent_request, mode: mode)
      expect(effects).to be_empty
      receipt = parent.reconcile_approval(recovery: recovery)
      expect(receipt).to be_resolved, receipt.error&.cause&.full_message
      continuation = if mode == :pre
        expect(effects).to be_empty
        parent.approve_async(root_id, approval_request_id: parent_request.id, approved: true)
      else
        receipt.execution_task
      end
      child_request = Timeout.timeout(8) { events.pop }
      expect { result_of(continuation) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
      expect(effects).to eq(["parent check"])
      child = child_class.get(stores.agent.execution_identity(child_request.execution_id).agent_id)
      expect { @child_answer = result_of(child.approve_async(child_request.execution_id, approval_request_id: child_request.id, approved: true)) }.not_to raise_error
      expect(@child_answer).to include(output: "child completed")
      # The local Tool already ran, but this mixed-batch coordination checkpoint
      # has no durable result for that Tool. This is also true before G3h.
      # Recovery must leave factual resolution to the application, not replay it.
      expect { parent.resume(root_id) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
      expect(effects).to eq(["parent check", "check"])
      expect(@recorder.calls.size).to eq(3)
      expect(stores.agent.executions.load(root_id).phase).to eq(:dispatching_tools)
      expect(stores.agent.executions.load(child_request.execution_id).status).to eq(:completed)
      fact = Timeout.timeout(8) { resolution_events.pop }
      expect(fact.fetch(:facts).fetch(:tool_name)).to eq("approval_required_tool")
      resolved = result_of(parent.resolve_async(root_id,
        expected_execution_revision: fact.fetch(:execution_revision), subject: fact.fetch(:subject),
        outcome: :succeeded, result: "approved parent check"))
      expect(resolved).to include(output: "parent completed")
      expect(parent.resume(root_id)).to include(output: "parent completed")
      expect(effects).to eq(["parent check", "check"])
      expect(@recorder.calls.size).to eq(4)
      expect(parent.unload_with_completed_child!(root_id, execution_id: child_request.execution_id)).to be(true)
    end

    it "keeps known #{mode} approval facts while requiring fresh native child authority" do
      @recorder = LLMStub.activate(responses: [dispatch, protected_call, "child completed", protected_call, "parent completed"])
      start_parent
      child_request = Timeout.timeout(8) { events.pop }
      expect { result_of(@original) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
      child = child_class.get(stores.agent.execution_identity(child_request.execution_id).agent_id)
      result_of(child.approve_async(child_request.execution_id, approval_request_id: child_request.id, approved: true))
      continued = parent.resume_async(root_id)
      parent_request = Timeout.timeout(8) { events.pop }
      expect { result_of(continued) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
      recovery = start_decision_recovery(parent_request, mode: mode)
      hold = stores.agent.retained_references(agent_id: child.agent_id).find { |value| value.owner_key == "subagent:#{root_id}" }
      expect(hold).not_to be_nil
      stores.agent.coordinator.atomic do |scope|
        stores.agent.release_retention(agent_id: child.agent_id, owner_key: hold.owner_key, scope: scope)
      end
      blocked = parent.reconcile_approval(recovery: recovery)
      expect(blocked.outcome).to eq((mode == :pre) ? :confirmed_pre : :confirmed_post)
      expect(blocked).not_to be_resolved
      expect(blocked.execution_task).to be_nil
      expect(blocked.error.cause).to be_a(Phronomy::Persistence::StateConflictError)
      expect_parent_retained
      expect(effects).to eq(["check"])
      expect(@recorder.calls.size).to eq(4)
      stores.agent.retain(hold)
      receipt = parent.reconcile_approval(recovery: recovery)
      expect(receipt).to be_resolved, receipt.error&.cause&.full_message
      continuation = (mode == :pre) ? parent.approve_async(root_id, approval_request_id: parent_request.id, approved: true) : receipt.execution_task
      expect(result_of(continuation)).to include(output: "parent completed")
      expect(effects).to eq(["check", "check"])
      expect(@recorder.calls.size).to eq(5)
      expect(parent.unload_with_completed_child!(root_id, execution_id: child_request.execution_id)).to be(true)
    end
  end

  it "preserves recovered coordination authority when registry release succeeds but its reply is lost" do
    @recorder = LLMStub.activate(responses: [dispatch, protected_call, "child completed", "parent completed"])
    lose_save(boundary: :coordination_wait, mode: :post)
    start_outcome_recovery
    request = Timeout.timeout(8) { events.pop }
    registry = parent.__execution_environment.registry
    armed = true
    allow(registry).to receive(:release_terminal_operation).and_wrap_original do |original, owner|
      result = original.call(owner)
      if armed
        armed = false
        raise IOError, "Registry release completed but reply was lost"
      end
      result
    end
    receipt = finish_outcome(:post, :coordination_wait)
    expect(receipt.ownership_state).to eq(:released)
    coordinator = parent.send(:execution_coordinator)
    wait = coordinator.recovered_coordination_wait
    expect(wait.execution_id).to eq(root_id)
    expect(wait).to be_current
    expect do
      result_of(parent.approve_hosted_child(root_id, execution_id: request.execution_id,
        approval_request_id: request.id, approved: true))
    end.to raise_error(Phronomy::AgentBusyError, "Hosted decision requires a restored child wait")
    # This child still has its original live wait, so its ordinary approval API
    # applies. Hosted child approval is reserved for a restored child wait.
    child = child_class.get(stores.agent.execution_identity(request.execution_id).agent_id)
    expect(result_of(child.approve_async(request.execution_id,
      approval_request_id: request.id, approved: true))).to include(output: "child completed")
    expect(parent.resume(root_id)).to include(output: "parent completed")
    expect(effects).to eq(["check"])
    expect(@recorder.calls.size).to eq(4)
    expect(parent.unload_with_completed_child!(root_id, execution_id: request.execution_id)).to be(true)
  end
end
