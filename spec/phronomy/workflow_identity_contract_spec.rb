# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe "CG-01 canonical Workflow instance identity" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:persistence) { Phronomy::Persistence::InMemory.new }

  let(:context_class) do
    Class.new do
      include Phronomy::WorkflowContext

      field :counter, default: 0
    end
  end

  let(:workflow) do
    Phronomy::Workflow.define(context_class, persistence: persistence) do
      initial :step
      state :step, action: ->(ctx) { ctx.merge(counter: ctx.counter + 1) }
      transition from: :step, to: :__finish__
    end
  end

  after do
    Phronomy.reset_runtime!
  rescue
    nil
  end

  it "exposes workflow_instance_id and removes the WorkflowContext thread_id alias" do
    expect(Phronomy::WorkflowContext.public_instance_methods(false))
      .to include(:workflow_instance_id)
    expect(Phronomy::WorkflowContext.public_instance_methods(false))
      .not_to include(:thread_id)
  end

  it "uses workflow_instance_id as the Workflow#signal keyword" do
    expect(Phronomy::Workflow.instance_method(:signal).parameters).to eq(
      [
        [:keyreq, :workflow_instance_id],
        [:keyreq, :event],
        [:key, :payload]
      ]
    )
  end

  it "uses workflow_instance_id as the durable Workflow key" do
    result = workflow.invoke(
      {counter: 0},
      config: {workflow_instance_id: "workflow-1"}
    )

    expect(result.workflow_instance_id).to eq("workflow-1")
    record = persistence.workflow_states.load("workflow-1")
    expect(record[:snapshot]["fields"]["counter"]).to eq(1)
    expect(record[:revision]).to eq(1)
  end

  it "keeps an existing durable key value unchanged across the rename" do
    persistence.workflow_states.save(
      "existing-key",
      expected_revision: nil,
      snapshot: {
        fields: {counter: 4},
        phase: "__end__"
      }
    )

    result = workflow.invoke(
      {},
      config: {workflow_instance_id: "existing-key"}
    )

    expect(result.workflow_instance_id).to eq("existing-key")
    expect(result.counter).to eq(5)
    expect(persistence.workflow_states.load("existing-key")[:revision]).to eq(2)
  end

  it "rejects legacy Workflow config thread_id instead of silently branching identity" do
    expect {
      workflow.invoke({}, config: {thread_id: "legacy-workflow"})
    }.to raise_error(
      ArgumentError,
      /thread_id.*workflow_instance_id/
    )

    expect(persistence.workflow_states.load("legacy-workflow")).to be_nil
  end

  it "does not derive Workflow identity from InvocationContext attributes" do
    # CG-02a removed thread_id from InvocationContext; verify that Workflow
    # identity is auto-generated and not taken from any InvocationContext field.
    invocation_context = Phronomy::InvocationContext.new(
      user_id: "app-user-xyz"
    )

    result = workflow.invoke({}, invocation_context: invocation_context)

    expect(result.workflow_instance_id).not_to eq("app-user-xyz")
    expect(result.workflow_instance_id).to match(/\A[0-9a-f-]{36}\z/)
  end

  it "renames the Workflow Persistence SPI parameter without creating a new durable key format" do
    repository = persistence.workflow_states

    expect(repository.method(:load).parameters).to eq(
      [[:req, :workflow_instance_id]]
    )
    expect(repository.method(:save).parameters).to include(
      [:req, :workflow_instance_id]
    )
    expect(repository.method(:delete).parameters).to include(
      [:req, :workflow_instance_id]
    )
  end

  it "preserves workflow_instance_id when a Workflow action replaces the context object" do
    # Capture before instance_eval: context_class is an RSpec let helper and
    # is not visible as a method on the Workflow::Builder.
    ctx_class = context_class
    replacement_workflow = Phronomy::Workflow.define(
      context_class,
      persistence: persistence
    ) do
      initial :step
      state :step, action: ->(_ctx) { ctx_class.new(counter: 9) }
      transition from: :step, to: :__finish__
    end

    result = replacement_workflow.invoke(
      {counter: 0},
      config: {workflow_instance_id: "replacement-workflow"}
    )

    expect(result.counter).to eq(9)
    expect(result.workflow_instance_id).to eq("replacement-workflow")
  end

  it "reserves workflow_instance_id against application field shadowing" do
    expect do
      Class.new do
        include Phronomy::WorkflowContext

        field :workflow_instance_id
      end
    end.to raise_error(ArgumentError, /workflow_instance_id.*reserved/)
  end

  it "uses the reconciled Runtime metadata protocol without making Workflow identity an FSMSession constructor key" do
    parameters = Phronomy::FSMSession.instance_method(:initialize).parameters

    expect(parameters).not_to include([:key, :id])
    expect(parameters).not_to include([:key, :graph_thread_id])
    expect(parameters).to include([:key, :context_metadata])
    expect(parameters).to include([:key, :identity_reservation])
    expect(parameters).not_to include([:key, :workflow_instance_id])
  end

  it "keeps RBS and the API snapshot on the canonical Workflow identity" do
    workflow_rbs = File.read(File.join(root, "sig/phronomy/workflow.rbs"))
    persistence_rbs = File.read(File.join(root, "sig/phronomy/persistence.rbs"))
    snapshot = JSON.parse(
      File.read(File.join(root, "spec/fixtures/api_snapshot.json"))
    )

    context_entry = snapshot.find { |entry|
      entry["name"] == "Phronomy::WorkflowContext"
    }

    expect(workflow_rbs).to include(
      "def workflow_instance_id: () -> String?"
    )
    expect(workflow_rbs).not_to include(
      "def thread_id: () -> String?"
    )
    expect(persistence_rbs).to match(
      /_WorkflowStateRepository.*workflow_instance_id/m
    )
    expect(context_entry.fetch("public_instance_methods"))
      .to include("workflow_instance_id")
    expect(context_entry.fetch("public_instance_methods"))
      .not_to include("thread_id")
  end

  it "records ADR-020 as the canonical identity authority without folding later ACS-13 concerns into CG-01" do
    adr = File.read(
      File.join(
        root,
        "docs/decisions/020-canonical-workflow-instance-identity.md"
      )
    )

    expect(adr).to include("workflow_instance_id")
    expect(adr).to include("No deprecated Workflow `thread_id` alias")
    expect(adr).to include("framework-owned WorkflowContext metadata")
    expect(adr).to include("WorkflowContext.field(:workflow_instance_id)")
    expect(adr).to include("Explicit non-goals")
    expect(adr).to include("opaque owner token/handle")
    expect(adr).to include("terminal/halt save")
    expect(adr).to include("cross-process ownership")
    expect(adr).to include("recovery")

    migration = File.read(
      File.join(root, "docs/migrations/0.22.md")
    )
    expect(migration).to include(
      "`workflow_instance_id` is framework-owned WorkflowContext metadata"
    )
    expect(migration).to include("field :workflow_instance_id")
    expect(migration).to include("ArgumentError")
  end
end
