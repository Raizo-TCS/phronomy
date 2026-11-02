# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Workflow saved events" do
  let(:context_class) do
    Class.new do
      include Phronomy::WorkflowContext

      field :result
    end
  end
  let(:store) { Phronomy::PersistenceComposition.in_memory.workflow }
  let(:applications) { [] }
  let(:guard_inputs) { [] }

  def definition(repository = store)
    apply_result = ->(ctx) {
      applications << ctx.result
      ctx
    }
    accepted = ->(ctx) {
      guard_inputs << ctx.result
      ctx.result == "approved"
    }
    Phronomy::Workflow.define(context_class, persistence: repository) do
      initial :prepare
      state :prepare
      wait_state :awaiting_child
      state :complete, action: apply_result
      transition from: :prepare, to: :awaiting_child
      transition from: :awaiting_child, on: :repeat, to: :prepare
      transition from: :awaiting_child, on: :child_done, to: :complete, guard: accepted
      transition from: :complete, to: :__finish__
    end
  end

  def send_result(app, revision:)
    app.send_saved_event(workflow_instance_id: "parent", expected_revision: revision,
      event: :child_done, input: {result: "approved"})
  end

  it "restores a saved wait without the caller's halted context and applies the result once" do
    definition.invoke({}, config: {workflow_instance_id: "parent"})
    revision = store.load("parent").fetch(:revision)
    restored = definition
    done = send_result(restored, revision: revision)

    expect(done).not_to be_halted
    expect(done.workflow_instance_id).to eq("parent")
    expect(done.result).to eq("approved")
    expect(store.load("parent")[:revision]).to eq(revision + 1)
    expect { send_result(restored, revision: revision) }.to raise_error(Phronomy::Persistence::StateConflictError)
    expect { send_result(restored, revision: revision + 1) }.to raise_error(ArgumentError, /No saved wait/)
    expect(applications).to eq(["approved"])
    expect(guard_inputs).to eq(["approved"])
  end

  it "rejects a stale wakeup even after returning to identical fields and phase" do
    app = definition
    app.invoke({}, config: {workflow_instance_id: "parent"})
    first = store.load("parent")
    app.send_saved_event(workflow_instance_id: "parent", expected_revision: first[:revision], event: :repeat)
    second = store.load("parent")

    expect(second[:snapshot]).to eq(first[:snapshot])
    expect(second[:revision]).to eq(first[:revision] + 1)
    expect { send_result(app, revision: first[:revision]) }.to raise_error(Phronomy::Persistence::StateConflictError)
    expect(store.load("parent")).to eq(second)
    expect(applications).to be_empty
    expect(guard_inputs).to be_empty
  end

  it "refuses a missing checkpoint or invalid event without starting the Workflow" do
    app = definition
    expect { send_result(app, revision: 1) }.to raise_error(Phronomy::Persistence::StateConflictError)
    expect(store.load("parent")).to be_nil
    app.invoke({}, config: {workflow_instance_id: "parent"})
    record = store.load("parent")
    expect {
      app.send_saved_event(workflow_instance_id: "parent", expected_revision: record[:revision], event: :unrelated)
    }.to raise_error(ArgumentError, /No saved wait/)
    expect(store.load("parent")).to eq(record)
    expect(applications).to be_empty
  end

  it "leaves the wait available when the event guard refuses the payload" do
    app = definition
    app.invoke({}, config: {workflow_instance_id: "parent"})
    record = store.load("parent")
    expect {
      app.send_saved_event(workflow_instance_id: "parent", expected_revision: record[:revision], event: :child_done)
    }.to raise_error(ArgumentError, /rejected/)
    expect(store.load("parent")).to eq(record)
    expect(applications).to be_empty
    expect(send_result(app, revision: record[:revision]).result).to eq("approved")
    expect(guard_inputs).to eq([nil, "approved"])
  end

  it "requires a stable identity, a positive revision, and a configured repository" do
    app = definition
    expect { app.send_saved_event(workflow_instance_id: "", expected_revision: 1, event: :child_done) }
      .to raise_error(ArgumentError, /workflow_instance_id/)
    expect { send_result(app, revision: nil) }.to raise_error(ArgumentError, /expected_revision/)
    expect { send_result(definition(nil), revision: 1) }.to raise_error(Phronomy::ConfigurationError)
  end
end
