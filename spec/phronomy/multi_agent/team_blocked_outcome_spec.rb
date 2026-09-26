# frozen_string_literal: true

require "spec_helper"
require_relative "support/durable_coordination"

RSpec.describe "Team propagation of blocked Agent outcomes" do
  include_context "durable coordination runtime"

  [:coordinator, :worker].product([:raise, :skip]).each do |role, on_error|
    it "preserves a blocked #{role} with on_error #{on_error} before and after restart" do
      team_class.pool(size: 1, agent: worker, on_error: on_error)
      team = team_class.create(team_id: "blocked-team", persistence: store)
      blocking_filter = Class.new(Phronomy::Filter::Base) do
        define_method(:call) { |_value, **_context| block!("child output rejected") }
      end
      if role == :worker
        worker.output_filter(blocking_filter)
      else
        allow(team).to receive(:coordinator_class).and_wrap_original do |original, id|
          original.call(id).tap { |klass| klass.output_filter(blocking_filter) }
        end
      end
      snapshots = {}
      store.after_commit = proc do |backend|
        run = backend.list_team_executions(team.team_id).first
        next unless run&.active?
        slot = (role == :worker) ? run.assignments.first : run.coordinator
        next unless slot
        begin
          child = backend.executions.load(slot.fetch("execution_id"))
          if child.status == :blocked
            boundary = (slot.fetch("state") == "blocked") ? :team_recorded : :child_terminal
            snapshots[boundary] ||= backend.snapshot
          end
        rescue Phronomy::Persistence::NotFoundError
          nil
        end
      end
      expected = (role == :worker && on_error == :skip) ? "completed" : "failed"
      llm = LLMStub.activate(responses: team_responses)
      check_blocked_team_result(expected) { team.invoke("plan") }
      expect(team.executions.first.status).to eq(expected)
      expect(llm.calls.size).to eq((role == :coordinator) ? 3 : 4)
      expect(snapshots.keys).to contain_exactly(:child_terminal, :team_recorded)
      snapshots.values.product([false, true]).each do |snapshot, cancel|
        restored = reboot(snapshot)
        loaded = team_class.load(team.team_id, persistence: restored)
        run = loaded.executions.first
        llm = LLMStub.activate(responses: ["must not replay"])
        loaded.cancel(run.team_execution_id) if cancel
        final_status = (cancel && expected == "completed") ? "cancelled" : expected
        check_blocked_team_result(final_status) { loaded.resume(run.team_execution_id) }
        run = loaded.executions.first
        expect(run.status).to eq(final_status)
        slot = (role == :worker) ? run.assignments.first : run.coordinator
        expect(slot.fetch("state")).to eq("blocked")
        expect(restored.executions.load(slot.fetch("execution_id")).status).to eq(:blocked)
        expect(llm.calls).to be_empty
      end
    end
  end

  def check_blocked_team_result(expected)
    if expected == "cancelled"
      expect { yield }.to raise_error(Phronomy::CancellationError)
    elsif expected == "failed"
      expect { yield }.to raise_error(Phronomy::Error, /child output rejected/)
    else
      expect(yield.first.fetch("error").fetch("message")).to include("child output rejected")
    end
  end
end
