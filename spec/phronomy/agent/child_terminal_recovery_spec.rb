# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Correlated child terminal recovery through the original Runtime" do
  include_context "a correlated child with uncertain persistence"

  [:pre, :post].each do |mode|
    it "recovers a #{mode} terminal save independently of the parent's observation" do
      configure_child_recovery(kind: :terminal, mode: mode)
      start_child_recovery
      observe_child_recovery
      if mode == :pre
        expect { child_result(@parent_original) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
      else
        expect(child_result(@parent_original)).to include(output: "parent completed")
        expect { parent.unload_with_completed_child!(root_id, execution_id: @child_execution_id) }
          .to raise_error(Phronomy::AgentBusyError)
      end
      expect_child_owner_retained
      calls_before = @child_recorder.calls.size
      receipt = child_reconcile
      if mode == :pre
        expect(receipt.outcome).to eq(:confirmed_pre)
        expect(receipt.ownership_state).to eq(:retained)
        expect_child_owner_retained
        receipt = child_retry
      end
      expect(receipt.outcome).to eq(:confirmed_post)
      expect(receipt.ownership_state).to eq(:released)
      expect(receipt.execution.status).to eq(:completed)
      observed = stores.agent.observe_execution(agent_id: @recovery_child.agent_id, execution_id: @child_execution_id)
      expect(receipt.execution.reservation).to eq(observed.reservation)
      expect(receipt.execution.reservation.correlation).to eq(@child_before.metadata.fetch("reservation"))
      expect(receipt.execution.result).to eq("child completed")
      expect(@child_recorder.calls.size).to eq(calls_before)
      expect(effects).to eq(["once"])
      expect(child_pending_recovery).to be_nil
      expect(@child_registry.agent_execution_admitted?(@recovery_child.agent_id)).to be(false)
      expect_child_original_closed
      expect(finish_recovered_parent).to include(output: "parent completed")
      expect(@child_recorder.calls.size).to eq(4)
      expect(parent.unload_with_completed_child!(root_id, execution_id: @child_execution_id)).to be(true)
    end
  end

  [:failure, :cancellation].product([:pre, :post]).each do |ending, mode|
    it "records a real child #{ending} after #{mode} uncertainty without business replay" do
      behavior = if ending == :failure
        -> { raise IOError, "child action failed" }
      else
        -> {
          stores.agent.request_cancellation(agent_id: @recovery_child.agent_id, execution_id: @child_started_execution_id)
          raise Phronomy::CancellationError, "child action cancelled"
        }
      end
      configure_child_recovery(kind: :terminal, mode: mode, behavior: behavior)
      start_child_recovery
      observe_child_recovery
      count = @child_recorder.calls.size
      if mode == :post
        expect { child_result(@parent_original) }.to raise_error(Phronomy::Error)
        extension = stores.agent.execution_extension(agent_id: parent.agent_id, execution_id: root_id,
          binding_key: "phronomy.subagent")
        slot = stores.multi_agent.contents.fetch_json(extension.state_ref).fetch("children").first
        expect(slot.fetch("imported")).to be(false)
        expect(slot.fetch("terminal_acknowledgement")).to include("execution_id" => @child_execution_id)
        # Durable custody is established, but the child's local recovery owner
        # still prevents unloading either live Agent as a completed pair.
        expect { parent.unload_with_completed_child!(root_id, execution_id: @child_execution_id) }
          .to raise_error(Phronomy::AgentBusyError)
        expect_child_owner_retained
      end
      receipt = child_reconcile
      if mode == :pre
        expect(receipt.outcome).to eq(:confirmed_pre)
        expect_child_owner_retained
        receipt = child_retry
      end
      expect(receipt.outcome).to eq(:confirmed_post)
      expect(receipt.ownership_state).to eq(:released)
      expect(receipt.execution.status).to eq((ending == :failure) ? :failed : :cancelled)
      expect(receipt.execution.error).not_to be_nil
      expect(receipt.execution.reservation.correlation).to eq(@child_before.metadata.fetch("reservation"))
      expect(effects).to eq(["once"])
      expect(@child_recorder.calls.size).to eq(count)
      expect_child_original_closed
      expect(child_pending_recovery).to be_nil
      begin
        child_result(@parent_original)
      rescue Phronomy::Error, IOError
        # The original parent observation stays closed; later import has its
        # own exact-execution observation and retains the configured error policy.
        nil
      end
      parent_result = parent.resume(root_id)
      # Child cancellation is a failed required subtask under the parent's
      # existing on_error: :raise policy; it is not a parent cancellation request.
      expect(parent_result.fetch(:status)).to eq(:failed)
      expect(parent_result.fetch(:error)).not_to be_nil
      expect(@child_recorder.calls.size).to eq(count)
      expect(stores.agent.retained_references(agent_id: @recovery_child.agent_id)).not_to be_empty
      expect(@child_registry.agent_execution_admitted?(@recovery_child.agent_id)).to be(false)
      expect(@child_registry.agent_execution_admitted?(parent.agent_id)).to be(false)
      # Terminal custody acknowledgement permits local cleanup while preserving
      # the distinction from successful result import and durable history release.
      extension = stores.agent.execution_extension(agent_id: parent.agent_id, execution_id: root_id,
        binding_key: "phronomy.subagent")
      slot = stores.multi_agent.contents.fetch_json(extension.state_ref).fetch("children").first
      expect(slot.fetch("imported")).to be(false)
      expect(slot.fetch("terminal_acknowledgement")).to include("execution_id" => @child_execution_id,
        "status" => receipt.execution.status.to_s, "reservation" => receipt.execution.reservation.correlation)
      holds = stores.agent.retained_references(agent_id: @recovery_child.agent_id)
      expect(parent.unload_with_completed_child!(root_id, execution_id: @child_execution_id)).to be(true)
      expect(stores.agent.retained_references(agent_id: @recovery_child.agent_id)).to eq(holds)
    end
  end

  it "retains unreadable terminal evidence even after the parent has imported the result" do
    configure_child_recovery(kind: :terminal)
    start_child_recovery
    observe_child_recovery
    expect(child_result(@parent_original)).to include(output: "parent completed")
    allow(stores.agent.coordinator).to receive(:atomic).and_raise(IOError, "terminal proof unavailable")
    receipt = child_reconcile
    expect(receipt.outcome).to eq(:unavailable)
    expect(receipt.ownership_state).to eq(:retained)
    expect_child_owner_retained(persisted: false)
    allow(stores.agent.coordinator).to receive(:atomic).and_call_original
    expect(child_reconcile.ownership_state).to eq(:released)
    expect(effects).to eq(["once"])
    expect(@child_recorder.calls.size).to eq(4)
  end

  it "does not apply a terminal proposal after the saved child correlation diverges" do
    configure_child_recovery(kind: :terminal)
    start_child_recovery
    observe_child_recovery
    expect(child_result(@parent_original)).to include(output: "parent completed")
    saved = stores.agent.executions.load(@child_execution_id)
    reservation = saved.metadata.fetch("reservation").merge("slot" => "another-parent-slot")
    stores.agent.executions.save(@child_execution_id, expected_revision: saved.execution_revision,
      execution: saved.with(metadata: saved.metadata.merge("reservation" => reservation)))
    receipt = child_reconcile
    expect(receipt.outcome).to eq(:unresolved)
    expect(receipt.ownership_state).to eq(:retained)
    expect_child_owner_retained
    expect(effects).to eq(["once"])
    expect(@child_recorder.calls.size).to eq(4)
  end

  it "retains terminal custody until an owned read physically completes despite observer cancellation" do
    configure_child_recovery(kind: :terminal)
    start_child_recovery
    observe_child_recovery
    expect(child_result(@parent_original)).to include(output: "parent completed")
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
    first = @recovery_child.reconcile_terminal_async(recovery: @child_recovery)
    child_take(waiting.fetch(:entered))
    second = @recovery_child.reconcile_terminal_async(recovery: @child_recovery)
    first.cancel!
    child_owner_barrier
    expect(second).not_to be_done
    expect_child_owner_retained(persisted: false)
    expect(reads).to eq(1)
    waiting.fetch(:release) << true
    receipt = child_result(second)
    expect(receipt.ownership_state).to eq(:released)
    expect { child_result(first) }.to raise_error(Phronomy::CancellationError)
    expect(parent.unload_with_completed_child!(root_id, execution_id: @child_execution_id)).to be(true)
    expect(effects).to eq(["once"])
  end
end
