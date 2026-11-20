# frozen_string_literal: true

require "spec_helper"
require_relative "support/durable_coordination"

RSpec.describe "Team committed child output failures" do
  include_context "durable coordination runtime"

  def output_failure_filter(switch = {reject: true})
    Class.new(Phronomy::Filter::Base) do
      define_method(:call) do |value, **_context|
        if switch.fetch(:reject)
          raise Phronomy::Agent::OutputError.new(execution_id: "filter-output",
            schema_digest: "filter-contract", reason: "invalid_json", raw_output: value)
        end
        value
      end
    end
  end

  def expect_team_completion(status)
    case status
    when "failed"
      expect { yield }.to raise_error(Phronomy::Error, /invalid_json/)
    when "cancelled"
      expect { yield }.to raise_error(Phronomy::CancellationError)
    when "completed"
      value = yield
      expect(value.first.fetch("error")).to include("class" => "Phronomy::Agent::OutputError")
    end
  end

  def expect_worker_failure_recorded(team, backend, execution_id, status)
    execution = team.executions.find { |run| run.team_execution_id == execution_id }
    assignment = execution.assignments.first
    child = backend.agent.executions.load(assignment.fetch("execution_id"))
    expect(child.status).to eq(:failed)
    expect(assignment.fetch("state")).to eq("failed")
    expect(assignment.fetch("error_ref")).to eq(child.error_ref)
    expect(execution.status).to eq(status)
    expect(execution.phase).to eq(status)
    expect(backend.multi_agent.teams.load(team.team_id).lifecycle_status).to eq("idle")
  end

  [:raise, :skip].each do |policy|
    it "records and publishes a failed worker before applying on_error #{policy}" do
      team_class.pool(size: 1, agent: worker, on_error: policy)
      switch = {reject: true}
      worker.output_filter(output_failure_filter(switch))
      team = team_class.create(persistence: store.multi_agent)
      llm = LLMStub.activate(responses: team_responses)
      events = []
      terminal_status = (policy == :raise) ? "failed" : "completed"

      expect_team_completion(terminal_status) do
        team.stream("plan") { |entry| events << entry }
      end
      run = team.executions.first
      expect_worker_failure_recorded(team, store, run.team_execution_id, terminal_status)
      expect(events.size).to eq(1)
      expect(events.first.fetch(:type)).to eq(:task_failed)
      expect(events.first.fetch(:error)).to include("class" => "Phronomy::Agent::OutputError")
      calls_before_resume = llm.calls.size
      expect_team_completion(terminal_status) { team.resume(run.team_execution_id) }
      expect(llm.calls.size).to eq(calls_before_resume)

      # The failed execution must release Team admission for another request.
      switch[:reject] = false
      LLMStub.activate(responses: team_responses)
      expect(team.invoke("next plan").first.fetch("result")).to eq("worker-result")
      expect(team.executions.map(&:team_execution_id).uniq.size).to eq(2)
      expect(store.multi_agent.teams.load(team.team_id).lifecycle_status).to eq("idle")
    end
  end

  [:raise, :skip].each do |policy|
    it "records a coordinator output failure even when worker policy is #{policy}" do
      team_class.pool(size: 1, agent: worker, on_error: policy)
      team = team_class.create(persistence: store.multi_agent)
      filter = output_failure_filter
      allow(team).to receive(:coordinator_class).and_wrap_original do |original, id|
        original.call(id).tap { |klass| klass.output_filter(filter) }
      end
      LLMStub.activate(responses: team_responses)

      expect_team_completion("failed") { team.invoke("plan") }
      run = team.executions.first
      child = store.agent.executions.load(run.coordinator.fetch("execution_id"))
      expect(child.status).to eq(:failed)
      expect(run.coordinator.fetch("state")).to eq("failed")
      expect(run.coordinator.fetch("error_ref")).to eq(child.error_ref)
      expect(run.assignments).to be_empty
      expect(run.status).to eq("failed")
      expect(run.phase).to eq("failed")
      expect(store.multi_agent.teams.load(team.team_id).lifecycle_status).to eq("idle")

      restored = reboot(store.snapshot)
      loaded = team_class.load(team.team_id, persistence: restored.multi_agent)
      llm = LLMStub.activate(responses: ["must not execute"])
      expect_team_completion("failed") { loaded.resume(run.team_execution_id) }
      expect(llm.calls).to be_empty
      expect(loaded.executions.first.status).to eq("failed")
      expect(restored.multi_agent.teams.load(team.team_id).lifecycle_status).to eq("idle")
    end
  end

  [:raise, :skip].product([false, true]).each do |policy, cancel_before_resume|
    it "imports a committed failed worker after F4 with #{policy} and cancellation #{cancel_before_resume}" do
      # F0: the child fails after one Tool effect. F4: only committed records
      # survive, before Team imports that failure. No unconfirmed X0 is replayed.
      effects = []
      tool = Class.new(Phronomy::Tool::Base) do
        tool_name "team_output_effect"
        description "Record one confirmed effect"
        define_method(:execute) do
          effects << "performed"
          "effect complete"
        end
      end
      worker.tools(tool => nil)
      worker.output_filter(output_failure_filter)
      team_class.pool(size: 1, agent: worker, on_error: policy)
      team = team_class.create(persistence: store.multi_agent)
      checkpoint = nil
      store.after_commit = proc do |backend|
        backend.backend.transaction do
          next if checkpoint
          run = backend.multi_agent.runs(team.team_id).first
          assignment = run&.assignments&.first
          next unless run&.active? && assignment && assignment.fetch("state") == "reserved"
          begin
            child = backend.agent.executions.load(assignment.fetch("execution_id"))
            checkpoint = backend.snapshot if child.status == :failed
          rescue Phronomy::Persistence::NotFoundError
            nil
          end
        end
      end
      initial_status = (policy == :raise) ? "failed" : "completed"
      responses = team_responses.take(3) + [LLMStub.tool_call_response("team_output_effect", {}), "invalid output"]
      LLMStub.activate(responses: responses)
      begin
        expect_team_completion(initial_status) { team.invoke("plan") }
      ensure
        store.after_commit = nil
      end
      expect(checkpoint).not_to be_nil
      expect(effects).to eq(["performed"])

      restored = reboot(checkpoint)
      loaded = team_class.load(team.team_id, persistence: restored.multi_agent)
      run = loaded.executions.first
      child_id = run.assignments.first.fetch("execution_id")
      expect(run.status).to eq("active")
      expect(run.assignments.first.fetch("state")).to eq("reserved")
      expect(restored.agent.executions.load(child_id).status).to eq(:failed)
      llm = LLMStub.activate(responses: ["must not execute"])
      loaded.cancel(run.team_execution_id) if cancel_before_resume
      terminal_status = if policy == :raise
        "failed"
      elsif cancel_before_resume
        "cancelled"
      else
        "completed"
      end
      expect_team_completion(terminal_status) { loaded.resume(run.team_execution_id) }
      expect_worker_failure_recorded(loaded, restored, run.team_execution_id, terminal_status)
      expect(llm.calls).to be_empty
      expect(effects).to eq(["performed"])

      # Re-observing the terminal Team after another restart repeats no child work.
      terminal_store = reboot(restored.snapshot)
      terminal_team = team_class.load(team.team_id, persistence: terminal_store.multi_agent)
      llm = LLMStub.activate(responses: ["must not execute"])
      expect_team_completion(terminal_status) { terminal_team.resume(run.team_execution_id) }
      expect(llm.calls).to be_empty
      expect(effects).to eq(["performed"])
    end
  end
end
