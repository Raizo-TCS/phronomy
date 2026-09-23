# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Recovered execution continuation ownership (F2/F3; no X0 dispatch)" do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "recovered-execution-contract", version: 1
      model "local-model"
    end
  end
  let(:agent) { agent_class.new(agent_id: "continuation-owner", persistence: Phronomy::Persistence.in_memory) }
  let(:coordinator) { agent.send(:execution_coordinator) }
  let(:runtime) { Phronomy::Runtime.instance }
  let(:registry) { Phronomy::Agent::ExecutionRegistry.for(runtime.event_loop) }
  let(:execution) do
    record = Phronomy::Agent::JournalRecord.new(
      agent_id: agent.agent_id, execution_id: "recovered-execution",
      kind: :user_message, channel: :llm, role: :user,
      content_ref: agent.persistence.contents.put_text("input"),
      context_generation: agent.agent_root.transcript_generation,
      context_candidate: true
    )
    Phronomy::Agent::AgentExecution.start(agent_root: agent.agent_root,
      input_record: record, execution_id: "recovered-execution").with(
        status: :active, phase: :recovery_provider_completed
      )
  end
  let(:invocation) do
    Phronomy::Agent::AgentInvocation.new(agent: agent, input: nil, config: {},
      execution_id: execution.execution_id)
  end
  let(:result_task) { Phronomy::TaskResult.deferred(name: "recovered-contract-result") }

  def on_loop(&action)
    completed = Phronomy::TaskResult.deferred(name: "contract-event-loop")
    handler = Object.new
    handler.define_singleton_method(:deliver_on_event_loop) do |_command|
      completed.complete(action.call)
    rescue => error
      completed.fail(error)
    end
    command = Struct.new(:coordinator).new(handler)
    registry.post(command, completion: completed)
    completed.wait_result(timeout: 3)
  end

  def continuation(**changes)
    Phronomy::Agent::ExecutionCoordinator::ContinueRecoveredCommand.new(
      coordinator: coordinator,
      execution_id: execution.execution_id,
      expected_execution_revision: execution.execution_revision,
      continuation: :output,
      invocation: invocation,
      runtime_projection: nil,
      result_task: result_task,
      error: nil,
      **changes
    )
  end

  def install(**changes)
    attributes = {
      execution_id: execution.execution_id, agent: agent,
      coordinator: coordinator, execution: execution,
      runtime_projection: nil, base_manifest: nil,
      invocation: nil, fsm_session_id: nil
    }.merge(changes)
    on_loop { registry.install_agent_execution(**attributes) }
  end

  after do
    on_loop { registry.release_agent_execution(execution.execution_id) }
    Phronomy.reset_runtime!
  end

  it "rejects a continuation outside EventLoop before installing live state" do
    original = install
    expect { coordinator.deliver_on_event_loop(continuation) }
      .to raise_error(Phronomy::Error, /must run on EventLoop/)
    expect(on_loop { registry.agent_execution_state(execution.execution_id) }).to equal(original)
  end

  [:revision, :owner, :coordinator, :session, :terminal].each do |conflict|
    it "leaves the current state untouched for a #{conflict} conflict" do
      replacement = case conflict
      when :revision then {execution: execution.with(metadata: {"newer" => true})}
      when :owner then {agent: agent_class.new(agent_id: "other-owner", persistence: Phronomy::Persistence.in_memory)}
      when :coordinator then {coordinator: Phronomy::Agent::ExecutionCoordinator.new(agent)}
      when :session then {fsm_session_id: "already-running-session"}
      when :terminal then {execution: execution.with(status: :completed, execution_revision: execution.execution_revision)}
      end
      original = install(**replacement)
      command = continuation
      expect { on_loop { coordinator.deliver_on_event_loop(command) } }
        .to raise_error(Phronomy::ExecutionRehydrationRequiredError, /stale recovered/)
      expect(on_loop { registry.agent_execution_state(execution.execution_id) }).to equal(original)
    end
  end

  it "rejects an invocation from another execution before replacing live state" do
    original = install
    other = Phronomy::Agent::AgentInvocation.new(agent: agent, input: nil,
      config: {}, execution_id: "other-execution")
    command = continuation(invocation: other)
    expect { on_loop { coordinator.deliver_on_event_loop(command) } }
      .to raise_error(Phronomy::ExecutionRehydrationRequiredError, /does not belong/)
    expect(on_loop { registry.agent_execution_state(execution.execution_id) }).to equal(original)
  end

  [:followup, :unknown].each do |kind|
    it "rejects #{kind} at a saved Provider result before starting an FSM" do
      original = install
      command = continuation(continuation: kind)
      expect { on_loop { coordinator.deliver_on_event_loop(command) } }
        .to raise_error(Phronomy::ExecutionRehydrationRequiredError, /invalid recovered continuation/)
      expect(on_loop { registry.agent_execution_state(execution.execution_id) }).to equal(original)
    end
  end

  it "fails both observers for stale initial preparation without releasing another lifecycle" do
    original = install
    loaded = Phronomy::TaskResult.deferred(name: "stale-preparation-load")
    command = Phronomy::Agent::ExecutionCoordinator::RecoverPreparationCommand.new(
      coordinator: coordinator, execution_id: execution.execution_id,
      expected_execution_revision: execution.execution_revision - 1,
      result_task: result_task, load_completion: loaded
    )
    on_loop { coordinator.deliver_on_event_loop(command) }
    [result_task, loaded].each do |task|
      expect { task.wait_result(timeout: 3) }
        .to raise_error(Phronomy::ExecutionRehydrationRequiredError, /stale recovered/)
    end
    expect(on_loop { registry.agent_execution_state(execution.execution_id) }).to equal(original)
  end

  [:session, :coordinator].each do |changed|
    it "rejects a late completion after the #{changed} is replaced without committing its outcome" do
      current_owner = (changed == :coordinator) ? Phronomy::Agent::ExecutionCoordinator.new(agent) : coordinator
      current_session = (changed == :session) ? "new-session" : "old-session"
      original = install(invocation: invocation, fsm_session_id: current_session, coordinator: current_owner)
      command = Phronomy::Agent::ExecutionCoordinator::SessionFinishedCommand.new(
        coordinator: coordinator, execution_id: execution.execution_id,
        result_task: result_task, invocation: invocation,
        error: nil, fsm_session_id: "old-session"
      )
      on_loop { coordinator.deliver_on_event_loop(command) }
      expect { result_task.wait_result(timeout: 3) }
        .to raise_error(Phronomy::Error, /stale Agent terminal callback/)
      expect(on_loop { registry.agent_execution_state(execution.execution_id) }).to equal(original)
    end
  end
end
