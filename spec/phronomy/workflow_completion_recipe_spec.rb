# frozen_string_literal: true

require "spec_helper"
require_relative "../../scripts/check_readme_runnable"

RSpec.describe "Bounded Workflow completion recipe" do
  let(:receiver) do
    code = RunnableDocumentation.blocks(File.join(RunnableDocumentation::ROOT, "docs/workflow-completion.md")).first.last
    Object.new.tap { |object| object.singleton_class.class_eval(code.split("class RecipeAnswerAgent", 2).first) }
  end
  let(:workflow) { double("workflow", signal: true) }
  let(:errors) { [] }

  def forward(task, notifier: ->(error) { errors << error })
    receiver.forward_completion(task, workflow: workflow, workflow_instance_id: "one-live-stage",
      event: :answer_ready, on_delivery_error: notifier)
  end

  it "forwards an immediate result without rewriting its state" do
    task = Phronomy::TaskResult.completed({answer: "ready"})
    expect(workflow).to receive(:signal).with(workflow_instance_id: "one-live-stage",
      event: :answer_ready, payload: {answer: "ready"}).once.and_return(true)
    expect(forward(task)).to be_nil
    expect(task.wait_result).to eq(answer: "ready")
  end

  it "registers exactly one callback for a delayed result" do
    task = Phronomy::TaskResult.deferred
    expect(workflow).to receive(:signal).once.and_return(true)
    forward(task)
    task.complete({answer: "later"})
    task.complete({answer: "ignored second settlement"})
  end

  [IOError, Phronomy::CancellationError].each do |kind|
    it "forwards #{kind} without turning it into a delivery failure" do
      error = kind.new("operation")
      expect(workflow).to receive(:signal).with(workflow_instance_id: "one-live-stage",
        event: :answer_ready, payload: {error: error}).and_return(true)
      forward(Phronomy::TaskResult.failed(error))
      expect(errors).to be_empty
    end
  end

  it "notifies rejected admission once" do
    expect(workflow).to receive(:signal).once.and_return(false)
    forward(Phronomy::TaskResult.completed({}))
    expect(errors.map(&:message)).to eq(["Workflow did not accept answer_ready"])
  end

  it "notifies a raised signal failure once" do
    error = IOError.new("signal failed")
    expect(workflow).to receive(:signal).once.and_raise(error)
    forward(Phronomy::TaskResult.completed({}))
    expect(errors).to eq([error])
  end

  it "leaves a failing notifier to the existing callback logger without retry" do
    calls = 0
    logger = double("logger")
    Phronomy.configure { |config| config.logger = logger }
    expect(logger).to receive(:error).once
    allow(workflow).to receive(:signal).and_return(false)
    task = Phronomy::TaskResult.completed({answer: "done"})
    forward(task, notifier: ->(_) {
      calls += 1
      raise "notifier failed"
    })
    expect(calls).to eq(1)
    expect(task.wait_result).to eq(answer: "done")
  end

  it "treats separate registrations as separate subscriptions" do
    task = Phronomy::TaskResult.deferred
    expect(workflow).to receive(:signal).twice.and_return(true)
    2.times { forward(task) }
    task.complete({answer: "ready"})
  end
end
