# frozen_string_literal: true

require "spec_helper"
require_relative "support/durable_coordination"

RSpec.describe "Team admission failure boundaries" do
  include_context "durable coordination runtime"

  # Reproduce records accepted by earlier versions without bypassing the current
  # public input check in the operation under test. No child has started yet.
  def saved_team_with_context(value)
    team = team_class.create(persistence: store.multi_agent)
    run = team.send(:admit, "plan", {durable_context: {}})
    store.multi_agent.transaction do |tx|
      saved = run.with(metadata: run.metadata.merge("durable_context_ref" => tx.contents.put_json(value)))
      tx.team_executions.save(run.team_execution_id,
        expected_revision: run.execution_revision, execution: saved)
    end
    [team, run.team_execution_id]
  end

  def expect_failed_team_without_child(team, backend, execution_id)
    run = team.executions.find { |entry| entry.team_execution_id == execution_id }
    expect(run.status).to eq("failed")
    expect(run.phase).to eq("failed")
    expect(run.error_ref).not_to be_nil
    expect(run.assignments).to be_empty
    expect(backend.agent.observe_execution(agent_id: run.coordinator.fetch("agent_id"),
      execution_id: run.coordinator.fetch("execution_id")).absent?).to be(true)
    expect(backend.multi_agent.teams.load(team.team_id).lifecycle_status).to eq("idle")
    run
  end

  [:invoke, :stream].product([
    ["a String", "invalid"], ["nil", nil], ["an Array", []],
    ["a noncanonical Hash", {"value" => Object.new}]
  ]).each do |operation, (description, invalid_context)|
    it "rejects #{description} before #{operation} creates a Team execution" do
      team = team_class.create(persistence: store.multi_agent)
      llm = LLMStub.activate(responses: team_responses)
      events = []

      expect do
        team.public_send(operation, "plan", config: {durable_context: invalid_context}) { |event| events << event }
      end.to raise_error(ArgumentError)

      expect(team.executions).to be_empty
      expect(store.multi_agent.teams.load(team.team_id).lifecycle_status).to eq("idle")
      expect(llm.calls).to be_empty
      expect(events).to be_empty
      expect(team.invoke("next plan").first.fetch("result")).to eq("worker-result")
      expect(team.executions.size).to eq(1)
    end
  end

  ["invalid", nil, []].each do |invalid_context|
    it "fails a restored Team with saved #{invalid_context.inspect} context without inventing a child execution" do
      team, execution_id = saved_team_with_context(invalid_context)
      restored = reboot(store.snapshot)
      loaded = team_class.load(team.team_id, persistence: restored.multi_agent)
      llm = LLMStub.activate(responses: ["must not call the provider"])

      expect do
        loaded.resume(execution_id, config: {durable_context: {"corrected" => true}})
      end.to raise_error(Phronomy::Error, /durable_context/)
      run = expect_failed_team_without_child(loaded, restored, execution_id)
      expect(loaded.result(execution_id).fetch(:error).fetch("message")).to match(/durable_context/)
      expect(llm.calls).to be_empty

      # Failure is a durable Team result. Re-observation does not dispatch work.
      terminal_store = reboot(restored.snapshot)
      terminal_team = team_class.load(team.team_id, persistence: terminal_store.multi_agent)
      llm = LLMStub.activate(responses: team_responses)
      expect { terminal_team.resume(execution_id) }.to raise_error(Phronomy::Error, /durable_context/)
      expect(terminal_team.executions.first.to_h).to eq(run.to_h)
      expect(llm.calls).to be_empty

      expect(terminal_team.invoke("next plan").first.fetch("result")).to eq("worker-result")
      expect(terminal_team.executions.size).to eq(2)
      expect(terminal_store.multi_agent.teams.load(team.team_id).lifecycle_status).to eq("idle")
    end
  end

  [IOError, ArgumentError, Phronomy::ConfigurationError].each do |error_class|
    it "does not treat #{error_class} while reading child state as a confirmed admission rejection" do
      team, execution_id = saved_team_with_context({})
      unavailable = true
      allow(store.agent.executions).to receive(:load).and_wrap_original do |original, *args|
        raise error_class, "child state unavailable" if unavailable
        original.call(*args)
      end
      llm = LLMStub.activate(responses: team_responses)

      expect { team.resume(execution_id) }.to raise_error(error_class, /child state unavailable/)
      run = team.executions.first
      expect(run.status).to eq("active")
      expect(run.error_ref).to be_nil
      expect(store.multi_agent.teams.load(team.team_id).lifecycle_status).to eq("active")
      expect(llm.calls).to be_empty

      unavailable = false
      expect(team.resume(execution_id).first.fetch("result")).to eq("worker-result")
      expect(team.executions.size).to eq(1)
      expect(store.multi_agent.teams.load(team.team_id).lifecycle_status).to eq("idle")
    end
  end

  it "retains recovery when saving a confirmed rejection and reading it back both fail" do
    team, execution_id = saved_team_with_context("invalid")
    unavailable = true
    failed_write = false
    repository = store.multi_agent.team_executions
    allow(store.backend).to receive(:replace_record).and_wrap_original do |original, context, resource, **options|
      if unavailable && resource.id == "team.executions" && !options.fetch(:entry).attributes.fetch(:active)
        failed_write = true
        raise IOError, "terminal commit unavailable"
      end
      original.call(context, resource, **options)
    end
    allow(repository).to receive(:load).and_wrap_original do |original, id|
      raise IOError, "terminal readback unavailable" if unavailable && failed_write
      original.call(id)
    end
    llm = LLMStub.activate(responses: ["must not call the provider"])

    expect { team.resume(execution_id) }.to raise_error(IOError, /terminal readback unavailable/)
    expect(team.executions.first.status).to eq("active")
    expect(team.executions.first.error_ref).to be_nil
    expect(store.multi_agent.teams.load(team.team_id).lifecycle_status).to eq("active")
    expect(llm.calls).to be_empty

    unavailable = false
    expect { team.resume(execution_id) }.to raise_error(Phronomy::Error, /durable_context/)
    expect_failed_team_without_child(team, store, execution_id)
    expect(llm.calls).to be_empty
  end

  [:raise, :skip].product([:invoke, :stream]).each do |policy, operation|
    it "fails a #{operation} run after worker admission rejection even with on_error #{policy}" do
      worker.max_iterations(-1)
      team_class.pool(size: 1, agent: worker, on_error: policy)
      team = team_class.create(persistence: store.multi_agent)
      llm = LLMStub.activate(responses: team_responses)
      events = []

      expect do
        team.public_send(operation, "plan") { |event| events << event }
      end.to raise_error(Phronomy::Error, /max_iterations/)
      run = team.executions.first
      assignment = run.assignments.first
      expect(run.status).to eq("failed")
      expect(run.phase).to eq("failed")
      expect(run.coordinator.fetch("state")).to eq("completed")
      expect(store.agent.executions.load(run.coordinator.fetch("execution_id")).status).to eq(:completed)
      expect(assignment.fetch("state")).to eq("reserved")
      expect(store.agent.observe_execution(agent_id: run.workers.first.fetch("agent_id"),
        execution_id: assignment.fetch("execution_id")).absent?).to be(true)
      expect(team.result(run.team_execution_id).fetch(:error)).to include("code" => "agent.execution_rejected")
      expect(store.multi_agent.teams.load(team.team_id).lifecycle_status).to eq("idle")
      expect(events).to be_empty
      expect(llm.calls.size).to eq(3)

      worker.max_iterations(10)
      LLMStub.activate(responses: team_responses)
      expect(team.invoke("next plan").first.fetch("result")).to eq("worker-result")
      expect(team.executions.size).to eq(2)
    end
  end

  it "keeps an execution admitted after the rejected attempt available for resume" do
    worker.max_iterations(-1)
    team = team_class.create(persistence: store.multi_agent)
    llm = LLMStub.activate(responses: team_responses)
    competing_result = nil
    allow(team).to receive(:finish_rejected_child).and_wrap_original do |original, id, error|
      # Another valid caller wins the same reserved identity after rejection and
      # before Team confirms absence. Exercise actual admission and persistence.
      worker.max_iterations(10)
      run = team.executions.first
      assignment = run.assignments.first
      task = run.tasks.find { |entry| entry.fetch("id") == assignment.fetch("task_id") }
      owner = {"kind" => "team", "team_id" => team.team_id,
               "team_execution_id" => id, "slot" => task.fetch("id")}
      reservation = Phronomy::Agent::ReservedExecution.new(agent_id: error.agent_id,
        execution_id: error.execution_id, correlation: owner)
      competing_result = worker.get(error.agent_id).start_reserved_async(reservation: reservation,
        input: task.fetch("description"), config: {
          phronomy_admission: Phronomy::MultiAgent::ReservedChildAdmission.new(persistence: store.multi_agent, owner: owner)
        }).wait_result(timeout: 3)
      original.call(id, error)
    end

    expect { team.invoke("plan") }.to raise_error(Phronomy::ExecutionRehydrationRequiredError,
      /existing child execution/)
    run = team.executions.first
    expect(competing_result.fetch(:status)).to eq(:completed)
    expect(run.status).to eq("active")
    expect(run.error_ref).to be_nil
    expect(run.assignments.first.fetch("state")).to eq("reserved")
    expect(store.multi_agent.teams.load(team.team_id).lifecycle_status).to eq("active")
    expect(llm.calls.size).to eq(4)

    expect(team.resume(run.team_execution_id).first.fetch("result")).to eq("worker-result")
    expect(llm.calls.size).to eq(4)
    expect(team.executions.first.assignments.first.fetch("state")).to eq("completed")
    expect(store.multi_agent.teams.load(team.team_id).lifecycle_status).to eq("idle")
  end

  it "does not finalize a rejected worker when the guarded absence observation fails" do
    worker.max_iterations(-1)
    team = team_class.create(persistence: store.multi_agent)
    unavailable = true
    allow(store.agent).to receive(:observe_execution).and_wrap_original do |original, **options|
      raise IOError, "guarded child observation unavailable" if unavailable
      original.call(**options)
    end
    llm = LLMStub.activate(responses: team_responses)

    expect { team.invoke("plan") }.to raise_error(IOError, /guarded child observation unavailable/)
    run = team.executions.first
    expect(run.status).to eq("active")
    expect(run.error_ref).to be_nil
    expect(store.multi_agent.teams.load(team.team_id).lifecycle_status).to eq("active")
    expect(llm.calls.size).to eq(3)

    unavailable = false
    expect { team.resume(run.team_execution_id) }.to raise_error(Phronomy::Error, /max_iterations/)
    expect(team.executions.first.status).to eq("failed")
    expect(store.multi_agent.teams.load(team.team_id).lifecycle_status).to eq("idle")
    expect(llm.calls.size).to eq(3)
  end

  it "confirms the failed Team after its terminal commit response is lost" do
    team, execution_id = saved_team_with_context("invalid")
    lost_response = false
    store.after_commit = proc do |backend|
      next if lost_response
      run = backend.multi_agent.runs(team.team_id).first
      if run.status == "failed"
        lost_response = true
        raise IOError, "terminal commit response lost"
      end
    end
    llm = LLMStub.activate(responses: ["must not call the provider"])

    begin
      expect { team.resume(execution_id) }.to raise_error(Phronomy::Error, /durable_context/)
    ensure
      store.after_commit = nil
    end
    expect(lost_response).to be(true)
    expect_failed_team_without_child(team, store, execution_id)
    expect(llm.calls).to be_empty
  end

  it "resumes after a consumer fails while observing an already committed assignment" do
    team = team_class.create(persistence: store.multi_agent)
    llm = LLMStub.activate(responses: team_responses)

    expect do
      team.stream("plan") { |_entry| raise ArgumentError, "consumer failed" }
    end.to raise_error(ArgumentError, "consumer failed")
    run = team.executions.first
    expect(run.status).to eq("active")
    expect(run.assignments.first.fetch("state")).to eq("completed")
    calls_before_resume = llm.calls.size

    expect(team.resume(run.team_execution_id).first.fetch("result")).to eq("worker-result")
    expect(llm.calls.size).to eq(calls_before_resume)
    expect(store.multi_agent.teams.load(team.team_id).lifecycle_status).to eq("idle")
  end
end
