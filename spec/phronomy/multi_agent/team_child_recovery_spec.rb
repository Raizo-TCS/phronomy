# frozen_string_literal: true

require "spec_helper"
require_relative "support/durable_coordination"

RSpec.describe "Team-owned child persistence recovery" do
  include_context "durable coordination runtime"

  let(:effects) { [] }

  def eventually
    Timeout.timeout(8) do
      loop do
        value = yield
        return value if value
        sleep 0.002
      end
    end
  end

  def result_of(task) = task.wait_result(timeout: 8)

  def released?(id)
    Phronomy::Agent::Base.get(id).nil?
  rescue Phronomy::AgentBusyError
    false
  end

  def configure_team_recovery(role:, kind:, mode:)
    outcomes = effects
    action = Class.new(Phronomy::Tool::Base) do
      tool_name "team_recovery_action"
      description "Perform the assigned action once"
      define_method(:execute) do
        outcomes << "once"
        "action completed"
      end
    end
    worker.tools(action => nil)
    @llm = LLMStub.activate(responses: team_responses.take(3) +
      [LLMStub.tool_call_response("team_recovery_action", {}), "worker-result"])
    @team = team_class.create(persistence: store.multi_agent)
    @fault = {armed: true, readback: false, writes: 0}
    allow_any_instance_of(Phronomy::Agent::ExecutionChange).to receive(:perform).and_wrap_original do |original|
      change = original.receiver
      correlation = change.correlation
      matching_role = correlation && correlation["kind"] == "team" &&
        ((correlation["slot"] == "coordinator") == (role == :coordinator))
      updated = change.instance_variable_get(:@updated)
      target = matching_role && ((kind == :terminal && change.kind == :terminal) ||
        (kind == :provider && change.kind == :dispatch && updated&.phase == :calling_llm) ||
        (kind == :tool && change.kind == :dispatch && updated&.phase == :dispatching_tools))
      Thread.current[:team_child_recovery_fault] = !!target
      if target && @fault[:armed]
        @child_id, @execution_id = change.agent_id, change.execution_id
      end
      original.call
    ensure
      Thread.current[:team_child_recovery_fault] = nil
    end
    allow(store).to receive(:atomic).and_wrap_original do |original, *args, &transaction|
      if Thread.current[:team_child_recovery_fault] && @fault[:readback]
        @fault[:readback] = false
        raise IOError, "Team child immediate readback unavailable"
      end
      unless Thread.current[:team_child_recovery_fault] && @fault[:armed]
        next original.call(*args, &transaction)
      end
      @fault[:armed] = false
      @fault[:writes] += 1
      if mode == :pre
        original.call(*args) do |scope|
          transaction.call(scope)
          @fault[:readback] = true
          raise IOError, "Team child save rolled back and reply was lost"
        end
      else
        original.call(*args, &transaction)
        @fault[:readback] = true
        raise IOError, "Team child save committed and reply was lost"
      end
    end
  end

  %i[coordinator worker].each do |role|
    %i[tool provider terminal].each do |kind|
      %i[pre post].each do |mode|
        it "retains and recovers the #{role}'s #{mode} #{kind} save without replaying Team work" do
          configure_team_recovery(role: role, kind: kind, mode: mode)
          error_type = (kind == :terminal) ? Phronomy::Agent::TerminalRecoveryError : Phronomy::Agent::DispatchRecoveryError
          if kind == :terminal && mode == :post
            expect(@team.invoke("plan").first.fetch("result")).to eq("worker-result")
          else
            expect { @team.invoke("plan") }.to raise_error(error_type) { |error| @original_error = error }
          end
          expect(@fault[:writes]).to eq(1)
          child = eventually do
            Phronomy::Agent::Base.get(@child_id)
          rescue Phronomy::AgentBusyError
            false
          end
          expect(child).not_to be_nil
          registry = child.__execution_environment.registry
          family = (kind == :terminal) ? :terminal : :dispatch
          recovery = child.public_send("pending_#{family}_recovery", execution_id: @execution_id)
          expect(recovery).not_to be_nil
          expect(@original_error.recovery).to equal(recovery) if @original_error
          expect(registry.agent_execution_admitted?(@child_id)).to be(true)
          expect { child.unload! }.to raise_error(Phronomy::AgentBusyError)
          run = @team.executions.first
          if kind == :terminal && mode == :post
            # Durable result import and local child release are separate facts.
            expect(run.status).to eq("completed")
          else
            expect(run.status).to eq("active")
            slot = (role == :coordinator) ? run.coordinator : run.assignments.first
            expect(slot.fetch("state")).to eq("reserved")
            expect(run.error_ref).to be_nil
          end

          receipt = result_of(child.public_send("reconcile_#{family}_async", recovery: recovery))
          if mode == :pre
            expect(receipt.outcome).to eq(:confirmed_pre)
            expect(registry.agent_execution_admitted?(@child_id)).to be(true)
            receipt = result_of(child.public_send("retry_#{family}_async", recovery: recovery))
          end
          expect(receipt.outcome).to eq(:confirmed_post)
          expect(receipt.application_state).to eq(:applied)
          if kind == :terminal
            expect(receipt.ownership_state).to eq(:released)
            expect(receipt.execution.status).to eq(:completed)
          else
            expect(receipt.continuation_state).to eq(:resumed)
            result_of(receipt.execution_task)
          end
          expect(child.public_send("pending_#{family}_recovery", execution_id: @execution_id)).to be_nil
          expect(@team.resume(run.team_execution_id).first.fetch("result")).to eq("worker-result")
          completed = @team.executions.first
          expect(completed.status).to eq("completed")
          expect(completed.tasks.size).to eq(1)
          expect(completed.assignments.size).to eq(1)
          expect(completed.assignments.first.fetch("state")).to eq("completed")
          expect(effects).to eq(["once"])
          expect(@llm.calls.size).to eq(5)
          expect(store.agent.executions.load(@execution_id)).to be_terminal
          ids = ([completed.coordinator] + completed.workers).map { |slot| slot.fetch("agent_id") }
          eventually { ids.all? { |id| released?(id) } }
          expect(@team.instance_variable_get(:@coordinator_classes)).not_to have_key(run.team_execution_id)
        end
      end
    end
  end
end
