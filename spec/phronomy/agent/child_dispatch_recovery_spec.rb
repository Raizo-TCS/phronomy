# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Correlated child dispatch recovery through the original Runtime" do
  include_context "a correlated child with uncertain persistence"

  [:provider, :tool].each do |kind|
    [:pre, :post].each do |mode|
      it "recovers #{kind} #{mode} without replay and lets the parent import the exact child" do
        configure_child_recovery(kind: kind, mode: mode)
        start_child_recovery
        observe_child_recovery
        expect { child_result(@parent_original) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
        expect(stores.agent.executions.load(root_id).status).to eq(:active)
        expect(effects).to eq((kind == :provider) ? ["once"] : [])
        expect(@child_recorder.calls.size).to eq(2)
        receipt = child_reconcile
        if mode == :pre
          expect(receipt.outcome).to eq(:confirmed_pre)
          expect(receipt).not_to be_resolved
          expect_child_owner_retained
          receipt = child_retry
        end
        expect(receipt.outcome).to eq(:confirmed_post)
        expect(receipt.continuation_state).to eq(:resumed)
        expect(receipt).to be_resolved
        expect(child_result(receipt.execution_task)).to include(output: "child completed")
        expect(finish_recovered_parent).to include(output: "parent completed")
        expect_child_original_closed
        expect(effects).to eq(["once"])
        expect(@child_recorder.calls.size).to eq(4)
        expect(@child_fault[:writes]).to eq(1)
        expect(child_pending_recovery).to be_nil
        expect(parent.unload_with_completed_child!(root_id, execution_id: @child_execution_id)).to be(true)
      end
    end
  end

  [:provider, :tool].product([:reconcile, :retry]).each do |kind, action|
    it "rechecks cached #{kind} post evidence on #{action} before admitting work" do
      configure_child_recovery(kind: kind)
      start_child_recovery
      observe_child_recovery
      expect { child_result(@parent_original) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
      coordinator = child_owner_barrier { @child_registry.agent_execution_state(@child_execution_id).coordinator }
      allow(coordinator).to receive(:apply_retained_dispatch_on_event_loop).and_raise(IOError, "continuation handoff unavailable")
      first = child_reconcile
      expect(first.outcome).to eq(:confirmed_post)
      expect(first.continuation_state).to eq(:pending)
      allow(coordinator).to receive(:apply_retained_dispatch_on_event_loop).and_call_original
      saved = stores.agent.executions.load(@child_execution_id)
      changed = saved.metadata.fetch("reservation").merge("slot" => "another-parent-slot")
      stores.agent.executions.save(@child_execution_id, expected_revision: saved.execution_revision,
        execution: saved.with(metadata: saved.metadata.merge("reservation" => changed)))
      expect_any_instance_of(Phronomy::Agent::Persistence::ExecutionRepository).not_to receive(:save)
      receipt = (action == :retry) ? child_retry : child_reconcile
      expect(receipt.outcome).to eq(:confirmed_post)
      expect(receipt.continuation_state).to eq(:pending)
      expect(receipt).not_to be_resolved
      expect(receipt.error.cause).to be_a(Phronomy::Persistence::StateConflictError)
      expect_child_owner_retained
      expect(effects).to eq((kind == :provider) ? ["once"] : [])
      expect(@child_recorder.calls.size).to eq(2)
      expect_child_original_closed
    end
  end

  it "retains unreadable child proof and continues only after authoritative readback returns" do
    configure_child_recovery(kind: :tool)
    start_child_recovery
    observe_child_recovery
    expect { child_result(@parent_original) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    allow(stores.agent.coordinator).to receive(:atomic).and_raise(IOError, "child evidence unavailable")
    receipt = child_reconcile
    expect(receipt.outcome).to eq(:unavailable)
    expect(receipt).not_to be_resolved
    expect_child_owner_retained(persisted: false)
    expect(effects).to be_empty
    allow(stores.agent.coordinator).to receive(:atomic).and_call_original
    receipt = child_reconcile
    expect(child_result(receipt.execution_task)).to include(output: "child completed")
    expect(finish_recovered_parent).to include(output: "parent completed")
    expect(effects).to eq(["once"])
  end

  it "does not overwrite cancellation persisted after a confirmed child pre-state" do
    configure_child_recovery(kind: :tool, mode: :pre)
    start_child_recovery
    observe_child_recovery
    expect(child_reconcile.outcome).to eq(:confirmed_pre)
    stores.agent.request_cancellation(agent_id: @recovery_child.agent_id, execution_id: @child_execution_id)
    receipt = child_retry
    expect(receipt.outcome).to eq(:unresolved)
    expect(receipt).not_to be_resolved
    expect(stores.agent.cancellation_requested?(agent_id: @recovery_child.agent_id, execution_id: @child_execution_id)).to be(true)
    expect_child_owner_retained
    expect(effects).to be_empty
  end

  [:provider, :tool].each do |kind|
    it "honors cancellation already captured by the child's #{kind} proof" do
      configure_child_recovery(kind: kind)
      @child_fault[:capture_cancellation] = true
      start_child_recovery
      observe_child_recovery
      expect(stores.agent.cancellation_requested?(agent_id: @recovery_child.agent_id, execution_id: @child_execution_id)).to be(true)
      receipt = child_reconcile
      expect(receipt.outcome).to eq(:confirmed_post), receipt.error&.cause&.full_message
      expect { child_result(receipt.execution_task) }.to raise_error(Phronomy::CancellationError)
      expect(stores.agent.executions.load(@child_execution_id).status).to eq(:cancelled)
      expect(effects).to eq((kind == :provider) ? ["once"] : [])
      expect(@child_recorder.calls.size).to eq(2)
      expect_child_original_closed
    end
  end

  it "keeps the physical read and child owner when one recovery observer is cancelled" do
    configure_child_recovery(kind: :tool)
    start_child_recovery
    observe_child_recovery
    expect { child_result(@parent_original) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    waiting = child_gate
    reads = 0
    allow(stores.agent.coordinator).to receive(:atomic).and_wrap_original do |original, *args, &transaction|
      reads += 1
      if reads == 1
        waiting.fetch(:entered) << true
        waiting.fetch(:release).pop
      end
      original.call(*args, &transaction)
    end
    first = @recovery_child.reconcile_dispatch_async(recovery: @child_recovery)
    child_take(waiting.fetch(:entered))
    second = @recovery_child.reconcile_dispatch_async(recovery: @child_recovery)
    first.cancel!
    child_owner_barrier
    expect(second).not_to be_done
    expect_child_owner_retained(persisted: false)
    expect(effects).to be_empty
    expect(reads).to eq(1)
    waiting.fetch(:release) << true
    receipt = child_result(second)
    expect { child_result(first) }.to raise_error(Phronomy::CancellationError)
    expect(child_result(receipt.execution_task)).to include(output: "child completed")
    expect(finish_recovered_parent).to include(output: "parent completed")
    expect(effects).to eq(["once"])
  end
end
