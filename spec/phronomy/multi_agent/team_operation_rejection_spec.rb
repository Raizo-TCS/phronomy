# frozen_string_literal: true

require "spec_helper"
require_relative "support/durable_coordination"

RSpec.describe "Team operation rejection after a committed finalize" do
  include_context "durable coordination runtime"

  def late_enqueue_responses
    [LLMStub.tool_call_response("enqueue_task", {description: "accepted task"}),
      LLMStub.tool_call_response("finalize", {}),
      LLMStub.tool_call_response("enqueue_task", {description: "rejected task"})]
  end

  it "records a later-turn rejection as terminal failure and retains it across resume and reboot" do
    team = team_class.create(team_id: "late-enqueue", persistence: store.multi_agent)
    llm = LLMStub.activate(responses: late_enqueue_responses)

    expect { team.invoke("plan") }.to raise_error(Phronomy::Error, /Cannot enqueue after finalize/) { |error|
      expect(error).not_to be_a(Phronomy::ExecutionRehydrationRequiredError)
      expect(error.code).to eq("team.enqueue_after_finalize")
    }

    run = team.executions.first
    expect(run.status).to eq("failed")
    expect(run.metadata.fetch("finalized")).to be(true)
    expect(run.tasks.map { |task| task.fetch("description") }).to eq(["accepted task"])
    expect(run.assignments).to be_empty
    coordinator = store.agent.executions.load(run.coordinator.fetch("execution_id"))
    expect(coordinator.status).to eq(:failed)
    expect(store.agent.contents.fetch_json(coordinator.error_ref)).to include(
      "class" => "Phronomy::ConfigurationError", "message" => "Cannot enqueue after finalize",
      "code" => "team.enqueue_after_finalize"
    )
    expect(team.result(run.team_execution_id).dig(:error, "code")).to eq("team.enqueue_after_finalize")
    expect(llm.calls.size).to eq(3)

    expect { team.resume(run.team_execution_id) }.to raise_error(Phronomy::Error, /Cannot enqueue after finalize/) { |error|
      expect(error).not_to be_a(Phronomy::ExecutionRehydrationRequiredError)
      expect(error.code).to eq("team.enqueue_after_finalize")
    }
    expect(team.executions.first.to_h).to eq(run.to_h)
    expect(llm.calls.size).to eq(3)

    restored = reboot(store.snapshot)
    llm = LLMStub.activate(responses: ["must not call the provider"])
    loaded = team_class.load(team.team_id, persistence: restored.multi_agent)
    expect { loaded.resume(run.team_execution_id) }.to raise_error(Phronomy::Error, /Cannot enqueue after finalize/) { |error|
      expect(error).not_to be_a(Phronomy::ExecutionRehydrationRequiredError)
      expect(error.code).to eq("team.enqueue_after_finalize")
    }
    expect(loaded.executions.first.to_h).to eq(run.to_h)
    expect(llm.calls).to be_empty
  end

  it "replays an already committed enqueue with the same operation ID after finalize" do
    team = team_class.create(team_id: "operation-replay", persistence: store.multi_agent)
    LLMStub.activate(responses: team_responses)
    team.invoke("plan")
    run = team.executions.first
    key, operation = run.metadata.fetch("operations").find { |_id, entry| entry.fetch("operation") == "enqueue_task" }

    expect(team.send(:apply_operation, run.team_execution_id, key, :enqueue_task,
      operation.fetch("arguments"))).to eq(operation.fetch("result"))
    expect(team.executions.first.to_h).to eq(run.to_h)
  end

  [IOError, Phronomy::ConfigurationError].each do |readback_error|
    it "keeps recovery required when rejection readback raises #{readback_error}" do
      team = team_class.create(persistence: store.multi_agent)
      fail_readback = false
      allow(store.agent).to receive(:authorized_operations).and_wrap_original do |original, *args, **keywords|
        batch = original.call(*args, **keywords)
        run = store.multi_agent.runs(team.team_id).first
        fail_readback = true if keywords.fetch(:name) == "enqueue_task" && run.metadata["finalized"]
        batch
      end
      allow(team).to receive(:read_execution).and_wrap_original do |original, id|
        raise readback_error, "rejection readback unavailable" if fail_readback
        original.call(id)
      end
      LLMStub.activate(responses: late_enqueue_responses)

      expect { team.invoke("plan") }.to raise_error(Phronomy::ExecutionRehydrationRequiredError,
        /rejection readback unavailable/) { |error| expect(error.code).to be_nil }
      run = team.executions.first
      expect(run.status).to eq("active")
      expect(run.tasks.map { |task| task.fetch("description") }).to eq(["accepted task"])
      expect(store.agent.executions.load(run.coordinator.fetch("execution_id")).status).to eq(:active)
    end
  end

  it "does not classify an arbitrary ConfigurationError as a confirmed rejection" do
    team = team_class.create(persistence: store.multi_agent)
    allow(team).to receive(:apply_operation).and_raise(
      Phronomy::ConfigurationError.new("unconfirmed operation failure", code: "team.enqueue_after_finalize")
    )
    tool = team.send(:build_operation_tool, "run", :enqueue_task).new

    expect do
      tool.call_async({description: "task"}, config: {phronomy_tool_invocation_id: "unconfirmed"}).wait_result(timeout: 2)
    end.to raise_error(Phronomy::ExecutionRehydrationRequiredError, /unconfirmed operation failure/) { |error|
      expect(error.code).to be_nil
    }
  end
end
