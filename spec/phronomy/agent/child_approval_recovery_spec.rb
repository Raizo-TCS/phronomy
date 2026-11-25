# frozen_string_literal: true

require "spec_helper"
require_relative "../../integration/support/hosted_subagent"

RSpec.describe "Correlated child approval recovery through the original Runtime" do
  include_context "a native child requiring approval"

  let(:effects) { [] }

  before do
    RubyLLM.configure do |configuration|
      configuration.openai_protocol = :chat_completions
      configuration.openai_api_key = "test"
    end
    allow_any_instance_of(approval_tool).to receive(:execute).and_wrap_original do |original, query:|
      effects << query
      original.call(query: query)
    end
  end

  after do
    @gates&.each { |waiting| waiting.fetch(:release) << true }
    @runtime&.shutdown(timeout: 0.03, cancel_grace: 0.2)
  end

  def result_of(task) = task.wait_result(timeout: 8)
  def take(queue) = Timeout.timeout(8) { queue.pop }

  def eventually
    Timeout.timeout(8) do
      loop do
        result = yield
        return result if result
        sleep 0.002
      end
    end
  end

  def gate
    {entered: Queue.new, release: Queue.new}.tap { |waiting| (@gates ||= []) << waiting }
  end

  def restore_parent(request)
    restored = parent_class.load(parent.agent_id, **options)
    recovering = restored.resume_async(root_id)
    observed = take(events)
    expect([observed.execution_id, observed.id]).to eq([request.execution_id, request.id])
    expect { result_of(recovering) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    restored
  end

  def setup_child(hosted:, second_approval: false, approved: true)
    responses = [dispatch, protected_call]
    responses << LLMStub.tool_call_response("approval_required_tool", {query: "again"}) if second_approval
    responses << "child completed" if approved
    responses << "parent completed"
    @recorder = LLMStub.activate(responses: responses)
    @initial_handle, @request, @child = start
    @hosted = hosted
    @decision_parent = parent
    if hosted
      child_id = @child.agent_id
      detach(@initial_handle, @request)
      @decision_parent = restore_parent(@request)
      @child = child_class.get(child_id)
    end
    @before = stores.agent.executions.load(@request.execution_id)
    @registry = @child.__execution_environment.registry
    @environment = @child.__execution_environment
    @runtime = Phronomy::Runtime.instance
    expect(@before.metadata.fetch("reservation")).not_to be_nil
    expect(effects).to be_empty
  end

  def decide(approved: true)
    if @hosted
      @decision_parent.approve_hosted_child(root_id, execution_id: @request.execution_id,
        approval_request_id: @request.id, approved: approved)
    else
      @child.approve_async(@request.execution_id, approval_request_id: @request.id, approved: approved)
    end
  end

  def fail_next_decision(mode: :post)
    armed = true
    @decision_writes = 0
    allow(stores.agent).to receive(:transaction).and_wrap_original do |original, &transaction|
      next original.call(&transaction) unless armed
      armed = false
      @decision_writes += 1
      if mode == :pre
        original.call do |*arguments|
          transaction.call(*arguments)
          raise IOError, "child approval rolled back"
        end
      else
        original.call(&transaction)
        raise IOError, "child approval commit response lost"
      end
    end
  end

  def observe_failed_decision
    expect { result_of(@decision) }.to raise_error(Phronomy::Agent::ApprovalRecoveryError) do |error|
      @decision_error = error
      @recovery = error.recovery
    end
    expect(@recovery.execution_id).to eq(@request.execution_id)
    expect(@recovery.approval_request_id).to eq(@request.id)
    expect(@child.pending_approval_recovery(execution_id: @request.execution_id)).to equal(@recovery)
    expect(@registry.agent_execution_admitted?(@child.agent_id)).to be(true)
  end

  def start_unknown(mode: :post, approved: true)
    fail_next_decision(mode: mode)
    @decision = decide(approved: approved)
    observe_failed_decision
  end

  def reconcile = result_of(@child.reconcile_approval_async(recovery: @recovery))

  def expect_resumed(receipt, hosted_authority: @hosted)
    expect(receipt.outcome).to eq(:confirmed_post)
    expect(receipt.application_state).to eq(:applied)
    expect(receipt.continuation_state).to eq(:resumed)
    expect(receipt).to be_resolved
    expect(receipt).to be_physical_complete
    expect(receipt.execution_task).to be_a(Phronomy::TaskResult)
    if hosted_authority
      expect(receipt.hosted_invocation).to be_a(Phronomy::Agent::HostedInvocation)
      expect(receipt.hosted_invocation).not_to equal(@decision)
    else
      expect(receipt.hosted_invocation).to be_nil
    end
  end

  def expect_held(receipt)
    expect(receipt).not_to be_resolved
    expect(receipt.execution_task).to be_nil
    expect(receipt.hosted_invocation).to be_nil
    expect(@child.pending_approval_recovery(execution_id: @request.execution_id)).to equal(@recovery)
    expect(@registry.agent_execution_admitted?(@child.agent_id)).to be(true)
    expect { @child.unload! }.to raise_error(Phronomy::AgentBusyError)
    expect_live(@child)
    expect_live(@decision_parent)
    expect(effects).to be_empty
    expect(@recorder.calls.size).to eq(2)
  end

  [false, true].each do |hosted|
    context(hosted ? "with a restored parent's hosted decision" : "with a direct correlated child decision") do
      [true, false].each do |approved|
        it "recovers a committed approved=#{approved} decision once and preserves independent observations" do
          setup_child(hosted: hosted, approved: approved)
          start_unknown(approved: approved)
          saved = stores.agent.executions.load(@request.execution_id)
          expect(saved.status).to eq(:active)
          expect(saved.execution_revision).to eq(@before.execution_revision + 1)
          expect(saved.metadata.fetch("reservation")).to eq(@before.metadata.fetch("reservation"))

          receipt = reconcile
          expect_resumed(receipt)
          completed = result_of(receipt.execution_task)
          expect(completed).to include(approved ? {output: "child completed"} : {rejected: true})
          expect(result_of(receipt.hosted_invocation)).to eq(completed) if hosted
          expect(effects).to eq(approved ? ["check"] : [])
          again = reconcile
          expect_resumed(again, hosted_authority: false)
          expect(again.execution_task).not_to equal(receipt.execution_task)
          expect(result_of(again.execution_task)).to eq(completed)
          expect(@decision_writes).to eq(1)
          expect { result_of(@decision) }.to raise_error { |error| expect(error).to equal(@decision_error) }
          expect(@decision_parent.resume(root_id)).to include(output: "parent completed")
          expect(@recorder.calls.size).to eq(approved ? 4 : 3)
          expect(@decision_parent.unload_with_completed_child!(root_id, execution_id: @request.execution_id)).to be(true)
        end
      end

      it "restores a rolled-back wait and requires a fresh explicit decision" do
        setup_child(hosted: hosted)
        start_unknown(mode: :pre)
        expect(stores.agent.executions.load(@request.execution_id).to_h).to eq(@before.to_h)

        receipt = reconcile
        expect(receipt.outcome).to eq(:confirmed_pre)
        expect(receipt.continuation_state).to eq(:restored)
        expect(receipt).to be_resolved
        expect(receipt.execution_task).to be_nil
        expect(receipt.hosted_invocation).to be_nil
        expect(effects).to be_empty
        expect(@recorder.calls.size).to eq(2)
        expect(result_of(decide)).to include(output: "child completed")
        expect(effects).to eq(["check"])
        expect(reconcile.continuation_state).to eq(:restored)
        expect(@decision_parent.resume(root_id)).to include(output: "parent completed")
      end

      it "retains an unreadable decision and resolves a later authoritative observation" do
        setup_child(hosted: hosted)
        start_unknown
        allow(stores.agent.coordinator).to receive(:atomic).and_raise(IOError, "authority temporarily unavailable")
        receipt = reconcile
        expect(receipt.outcome).to eq(:unavailable)
        expect_held(receipt)
        allow(stores.agent.coordinator).to receive(:atomic).and_call_original

        receipt = reconcile
        expect_resumed(receipt)
        expect(result_of(receipt.execution_task)).to include(output: "child completed")
        expect(effects).to eq(["check"])
        expect(@decision_writes).to eq(1)
      end

      it "does not continue a divergent durable decision" do
        setup_child(hosted: hosted)
        start_unknown
        current = stores.agent.executions.load(@request.execution_id)
        stores.agent.executions.save(@request.execution_id, expected_revision: current.execution_revision,
          execution: current.with(approval_request: current.approval_request.merge("approved" => false)))

        receipt = reconcile
        expect(receipt.outcome).to eq(:unresolved)
        expect_held(receipt)
        expect(@decision_writes).to eq(1)
      end

      it "recovers a positively rejected initial evidence notification without repeating the decision" do
        setup_child(hosted: hosted)
        armed = true
        allow(@registry).to receive(:post).and_wrap_original do |original, message, **options|
          if armed && message.is_a?(Phronomy::Agent::ApprovalRecoveryOperation::Ready)
            armed = false
            false
          else
            original.call(message, **options)
          end
        end
        @decision = decide
        observe_failed_decision

        receipt = reconcile
        expect_resumed(receipt)
        expect(result_of(receipt.execution_task)).to include(output: "child completed")
        expect(effects).to eq(["check"])
        expect(@recorder.calls.size).to eq(3)
      end

      it "keeps an accepted save after callback failure until physical completion" do
        setup_child(hosted: hosted)
        waiting = gate
        admitted = Queue.new
        submissions = 0
        allow(@environment).to receive(:submit).and_wrap_original do |original, **options, &work|
          submissions += 1
          original.call(**options) do
            waiting.fetch(:entered) << true
            waiting.fetch(:release).pop
            work.call
          end.tap do |task|
            allow(task).to receive(:on_complete).and_raise(IOError, "child approval callback unavailable")
            admitted << task
          end
        end
        @decision = decide
        worker = take(admitted)
        take(waiting.fetch(:entered))
        observe_failed_decision
        receipt = reconcile
        expect(receipt.outcome).to eq(:unavailable)
        expect(receipt).not_to be_physical_complete
        expect_held(receipt)
        expect(submissions).to eq(1)
        allow(@environment).to receive(:submit).and_call_original
        waiting.fetch(:release) << true
        eventually { worker.physical_complete? }

        receipt = reconcile
        expect_resumed(receipt)
        expect(result_of(receipt.execution_task)).to include(output: "child completed")
        expect(effects).to eq(["check"])
      end
    end
  end

  it "returns an observable closed hosted handle when continuation finishes before public handle construction" do
    setup_child(hosted: true)
    coordinator = @registry.agent_execution_owner(@request.execution_id).coordinator
    allow(coordinator).to receive(:resume).and_wrap_original do |original, *arguments, **options|
      original.call(*arguments, **options).tap { |task| result_of(task) }
    end

    decision = decide
    expect(decision).to be_a(Phronomy::Agent::HostedInvocation)
    expect(result_of(decision)).to include(output: "child completed")
    expect { decision.detach!(execution_id: @request.execution_id, approval_request_id: @request.id) }
      .to raise_error(Phronomy::AgentBusyError)
    expect(effects).to eq(["check"])
    expect(@decision_parent.resume(root_id)).to include(output: "parent completed")
    expect(@recorder.calls.size).to eq(4)
  end

  it "retains a hosted decision when its parent's durable revision changes before recovery" do
    setup_child(hosted: true)
    start_unknown
    current = stores.agent.executions.load(root_id)
    stores.agent.executions.save(root_id, expected_revision: current.execution_revision,
      execution: current.with(status: current.status))

    expect_held(reconcile)
    expect { @decision.detach!(approval_request_id: @request.id) }.to raise_error(Phronomy::AgentBusyError)
  end

  [:parent, :child].each do |target|
    it "does not dispatch after a new durable #{target} cancellation changes hosted authority" do
      setup_child(hosted: true)
      start_unknown
      agent, execution_id = (target == :parent) ? [@decision_parent, root_id] : [@child, @request.execution_id]
      stores.agent.request_cancellation(agent_id: agent.agent_id, execution_id: execution_id)

      expect_held(reconcile)
      expect(stores.agent.cancellation_requested?(agent_id: agent.agent_id, execution_id: execution_id)).to be(true)
    end
  end

  [true, false].each do |approve_second|
    it "preserves the recovered hosted handle through a second approval and fresh owners, approved=#{approve_second}" do
      setup_child(hosted: true, second_approval: true, approved: approve_second)
      start_unknown
      receipt = reconcile
      expect_resumed(receipt)
      second = take(events)
      expect(second.execution_id).to eq(@request.execution_id)
      expect(second.id).not_to eq(@request.id)
      expect(effects).to eq(["check"])
      saved = saved_state(second.execution_id)

      expect { @decision.detach!(execution_id: second.execution_id, approval_request_id: second.id) }
        .to raise_error(Phronomy::AgentBusyError)
      expect { receipt.hosted_invocation.detach!(execution_id: second.execution_id, approval_request_id: @request.id) }
        .to raise_error(Phronomy::AgentBusyError)
      expect(saved_state(second.execution_id)).to eq(saved)
      wait = receipt.hosted_invocation.detach!(execution_id: second.execution_id, approval_request_id: second.id)
      expect([wait.execution_id, wait.approval_request_id]).to eq([second.execution_id, second.id])
      expect(result_of(receipt.execution_task)).to eq(wait)
      expect(result_of(receipt.hosted_invocation)).to eq(wait)
      historical = reconcile
      expect_resumed(historical, hosted_authority: false)
      expect(result_of(historical.execution_task)).to eq(wait)
      expect { receipt.hosted_invocation.detach!(execution_id: second.execution_id, approval_request_id: second.id) }
        .to raise_error(Phronomy::AgentBusyError)
      expect(saved_state(second.execution_id)).to eq(saved)
      expect(parent_class.get(@decision_parent.agent_id)).to be_nil
      expect(child_class.get(@child.agent_id)).to be_nil

      final_parent = restore_parent(second)
      decision = final_parent.approve_hosted_child(root_id, execution_id: second.execution_id,
        approval_request_id: second.id, approved: approve_second)
      expect(result_of(decision)).to include(approve_second ? {output: "child completed"} : {rejected: true})
      expect(final_parent.resume(root_id)).to include(output: "parent completed")
      expect(effects).to eq(approve_second ? ["check", "again"] : ["check"])
      expect { @decision.wait_result(timeout: 8) }.to raise_error { |error| expect(error).to equal(@decision_error) }
    end
  end

  [:revision, :cancellation].each do |change|
    it "rechecks parent #{change} before continuing a partially admitted hosted plan" do
      setup_child(hosted: true)
      start_unknown
      registrations = []
      allow(@environment).to receive(:register_session).and_wrap_original do |original, session, **options|
        registrations << session.id
        raise IOError, "Tool registration refused before admission" if registrations.size == 2
        original.call(session, **options)
      end
      partial = reconcile
      expect(partial.outcome).to eq(:confirmed_post)
      expect(partial.application_state).to eq(:applied)
      expect(partial.continuation_state).to eq(:pending)
      expect_held(partial)
      captured_ids = registrations.dup
      expect(captured_ids.size).to eq(2)
      if change == :revision
        current = stores.agent.executions.load(root_id)
        stores.agent.executions.save(root_id, expected_revision: current.execution_revision,
          execution: current.with(status: current.status))
      else
        stores.agent.request_cancellation(agent_id: @decision_parent.agent_id, execution_id: root_id)
      end

      expect_held(reconcile)
      expect(registrations).to eq(captured_ids)
      expect(@decision_writes).to eq(1)
    end
  end

  it "refuses old hosted authority after a new parent attempt without a durable revision change" do
    setup_child(hosted: true)
    start_unknown
    before = stores.agent.executions.load(root_id).to_h
    waiting = gate
    parent_environment = @decision_parent.__execution_environment
    armed = true
    allow(parent_environment).to receive(:submit).and_wrap_original do |original, **options, &work|
      next original.call(**options, &work) unless armed
      armed = false
      original.call(**options) do
        waiting.fetch(:entered) << true
        waiting.fetch(:release).pop
        work.call
      end
    end
    later = @decision_parent.invoke_async("a new parent request")
    take(waiting.fetch(:entered))
    expect(stores.agent.executions.load(root_id).to_h).to eq(before)

    expect_held(reconcile)
    expect(@decision_writes).to eq(1)
    waiting.fetch(:release) << true
    expect { result_of(later) }.to raise_error(Phronomy::AgentBusyError)
    expect(stores.agent.executions.load(root_id).to_h).to eq(before)
    expect_held(reconcile)
  end

  it "does not let the original parent start handle adopt a direct child's next approval" do
    setup_child(hosted: false, second_approval: true, approved: false)
    start_unknown
    receipt = reconcile
    expect_resumed(receipt)
    second = take(events)
    expect(second.id).not_to eq(@request.id)
    saved = saved_state(second.execution_id)
    expect { @initial_handle.detach!(execution_id: second.execution_id, approval_request_id: second.id) }
      .to raise_error(Phronomy::AgentBusyError)
    expect(saved_state(second.execution_id)).to eq(saved)
    expect_live(@child)
    expect_live(@decision_parent)
    decided = @child.approve_async(second.execution_id, approval_request_id: second.id, approved: false)
    expect(result_of(decided)).to include(rejected: true)
    expect(result_of(receipt.execution_task)).to include(rejected: true)
    expect(effects).to eq(["check"])
    expect(@decision_parent.resume(root_id)).to include(output: "parent completed")
  end

  it "keeps hosted continuation authority when an independent execution observer is cancelled" do
    setup_child(hosted: true, second_approval: true)
    start_unknown
    receipt = reconcile
    expect_resumed(receipt)
    receipt.execution_task.cancel!
    second = take(events)
    expect(effects).to eq(["check"])
    wait = receipt.hosted_invocation.detach!(execution_id: second.execution_id, approval_request_id: second.id)
    expect(result_of(receipt.hosted_invocation)).to eq(wait)
    expect { result_of(receipt.execution_task) }.to raise_error(Phronomy::CancellationError)
    expect(parent_class.get(@decision_parent.agent_id)).to be_nil
    expect(child_class.get(@child.agent_id)).to be_nil
  end
end

RSpec.describe "Approval recovery on a rehydrated standalone owner" do
  after do
    @runtime&.shutdown(timeout: 0.03, cancel_grace: 0.2)
    LLMStub.deactivate
  end

  [[:pre, false], [:post, false], [:pre, true]].each do |mode, captured_cancel|
    it "recovers #{mode} evidence with captured cancellation=#{captured_cancel} on the exact loaded wait" do
      RubyLLM.configure do |configuration|
        configuration.openai_protocol = :chat_completions
        configuration.openai_api_key = "test"
      end
      effects = []
      tool = IntegrationFactors.approval_tool(result_value: "applied")
      allow_any_instance_of(tool).to receive(:execute).and_wrap_original do |original, query:|
        effects << query
        original.call(query: query)
      end
      klass = IntegrationFactors.approval_resume_agent(tool)
      events = Queue.new
      callback = ->(event) { events << event.payload.fetch(:request) if event.type == :approval_required }
      agent = klass.new(on_event: callback)
      reservation = Phronomy::Agent::ReservedExecution.new(agent_id: agent.agent_id, execution_id: SecureRandom.uuid)
      recorder = LLMStub.activate(responses: [LLMStub.tool_call_response("approval_required_tool", {query: "check"}), "approved"])
      handle = agent.start_hosted(reservation: reservation, input: "run")
      request = Timeout.timeout(8) { events.pop }
      @runtime = Phronomy::Runtime.instance
      handle.detach!(approval_request_id: request.id)
      loaded_token = Phronomy::Concurrency::CancellationToken.new
      loaded = klass.load(agent.agent_id, persistence: agent.persistence, on_event: callback,
        execution_wiring: {cancellation_token: loaded_token})
      expect(Timeout.timeout(8) { events.pop }.id).to eq(request.id)
      before = loaded.persistence.executions.load(request.execution_id)
      expect(before.metadata["reservation"]).to be_nil
      loaded.persistence.request_cancellation(agent_id: loaded.agent_id, execution_id: request.execution_id) if captured_cancel
      armed = true
      allow(loaded.persistence).to receive(:transaction).and_wrap_original do |original, &transaction|
        next original.call(&transaction) unless armed
        armed = false
        if mode == :pre
          original.call do |*arguments|
            transaction.call(*arguments)
            raise IOError, "loaded approval rolled back"
          end
        else
          original.call(&transaction)
          raise IOError, "loaded approval response lost after commit"
        end
      end
      original = loaded.approve_async(request.execution_id, approval_request_id: request.id)
      failure = nil
      expect { original.wait_result(timeout: 8) }.to raise_error(Phronomy::Agent::ApprovalRecoveryError) { |error| failure = error }
      expect(loaded.pending_approval_recovery(execution_id: request.execution_id)).to equal(failure.recovery)
      receipt = loaded.reconcile_approval_async(recovery: failure.recovery).wait_result(timeout: 8)
      expect(receipt.outcome).to eq((mode == :pre) ? :confirmed_pre : :confirmed_post)
      expect(receipt).to be_resolved
      expect(receipt.hosted_invocation).to be_nil
      if captured_cancel
        expect(receipt.continuation_state).to eq(:restored)
        Timeout.timeout(8) do
          loop do
            break unless loaded.__execution_environment.registry.agent_execution_admitted?(loaded.agent_id)
            sleep 0.002
          end
        end
        expect(loaded.persistence.executions.load(request.execution_id).status).to eq(:cancelled)
        expect(loaded_token).not_to be_cancelled
      elsif mode == :pre
        expect(receipt.continuation_state).to eq(:restored)
        expect(effects).to be_empty
        expect(loaded.persistence.executions.load(request.execution_id).to_h).to eq(before.to_h)
        expect(loaded.approve_async(request.execution_id, approval_request_id: request.id).wait_result(timeout: 8))
          .to include(output: "approved")
      else
        expect(receipt.continuation_state).to eq(:resumed)
        expect(receipt.execution_task.wait_result(timeout: 8)).to include(output: "approved")
      end
      expect(effects).to eq(captured_cancel ? [] : ["check"])
      expect(recorder.calls.size).to eq(captured_cancel ? 1 : 2)
      expect { original.wait_result(timeout: 8) }.to raise_error { |error| expect(error).to equal(failure) }
      expect(loaded.unload!).to be(true)
    end
  end
end
