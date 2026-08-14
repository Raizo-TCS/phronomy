# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Workflow durable admission" do
  class WorkflowAdmissionContext
    include Phronomy::WorkflowContext

    field :value, type: :replace, default: 0
  end

  after do
    Phronomy.reset_runtime!
  rescue
    nil
  end

  it "keeps application session_id, durable thread_id, and fsm_session_id distinct" do
    workflow = Phronomy::Workflow.define(WorkflowAdmissionContext) do
      initial :waiting
      state :waiting
      state :done
      transition from: :waiting, on: :finish, to: :done
      transition from: :done, to: :__finish__
    end

    task = workflow.invoke_async(
      {value: 1},
      config: {thread_id: "workflow-42", session_id: "rails-session-7"}
    )
    event_loop = Phronomy::Runtime.instance.event_loop
    first_fsm_session_id = event_loop.workflow_admission_owner("workflow-42")

    expect(first_fsm_session_id).to be_a(String)
    expect(first_fsm_session_id).not_to eq("workflow-42")
    expect(first_fsm_session_id).not_to eq("rails-session-7")

    expect(workflow.signal(thread_id: "workflow-42", event: :finish)).to be(true)
    expect(task.wait_result.thread_id).to eq("workflow-42")

    second_task = workflow.invoke_async(
      {value: 2},
      config: {thread_id: "workflow-42", session_id: "rails-session-7"}
    )
    second_fsm_session_id = event_loop.workflow_admission_owner("workflow-42")

    expect(second_fsm_session_id).to be_a(String)
    expect(second_fsm_session_id).not_to eq(first_fsm_session_id)
    expect(workflow.signal(thread_id: "workflow-42", event: :finish)).to be(true)
    second_task.wait_result
  end

  it "does not let a non-owner release another FSMSession's thread admission" do
    event_loop = Phronomy::Runtime.instance.event_loop
    event_loop.admit_workflow(
      "workflow-42",
      owner_fsm_session_id: "fsm-owner"
    )

    expect(
      event_loop.release_workflow(
        "workflow-42",
        owner_fsm_session_id: "fsm-competitor"
      )
    ).to be(false)
    expect(event_loop.workflow_admission_owner("workflow-42")).to eq("fsm-owner")

    expect(
      event_loop.release_workflow(
        "workflow-42",
        owner_fsm_session_id: "fsm-owner"
      )
    ).to be(true)
  end

  it "keeps admission through terminal save so a competitor cannot stale-load" do
    persistence = Phronomy::Persistence::InMemory.new
    repository = persistence.workflow_states
    save_entered = Queue.new
    allow_save = Queue.new
    first_save = true

    blocking_repository = Object.new
    blocking_repository.define_singleton_method(:load) do |thread_id|
      repository.load(thread_id)
    end
    blocking_repository.define_singleton_method(:save) do |thread_id, expected_revision:, snapshot:|
      if first_save
        first_save = false
        save_entered << true
        allow_save.pop
      end
      repository.save(
        thread_id,
        expected_revision: expected_revision,
        snapshot: snapshot
      )
    end
    blocking_repository.define_singleton_method(:delete) do |thread_id, expected_revision:|
      repository.delete(thread_id, expected_revision: expected_revision)
    end
    allow(persistence).to receive(:workflow_states).and_return(blocking_repository)

    workflow = Phronomy::Workflow.define(
      WorkflowAdmissionContext,
      persistence: persistence
    ) do
      initial :done
      state :done, action: ->(context) { context.merge(value: context.value + 1) }
      transition from: :done, to: :__finish__
    end

    first = workflow.invoke_async({value: 0}, config: {thread_id: "shared"})
    save_entered.pop

    expect(Phronomy::Runtime.instance.event_loop.workflow_admission_owner("shared"))
      .not_to be_nil

    competitor = workflow.invoke_async({}, config: {thread_id: "shared"})
    expect { competitor.wait_result }
      .to raise_error(Phronomy::Error, /already owned/)

    expect(Phronomy::Runtime.instance.event_loop.workflow_admission_owner("shared"))
      .not_to be_nil

    allow_save << true
    expect(first.wait_result.value).to eq(1)
    expect(Phronomy::Runtime.instance.event_loop.workflow_admission_owner("shared"))
      .to be_nil
  end
end
