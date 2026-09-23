# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe "Feature execution drain boundaries (ADR-042; F0/F3, no X0)" do
  def take(queue)
    Timeout.timeout(3) { queue.pop }
  end

  def draining(event_loop)
    Timeout.timeout(3) { Thread.pass until event_loop.state == :draining }
  end

  it "returns false for a missing Workflow owner without registering during drain" do
    context_class = Class.new { include Phronomy::WorkflowContext }
    workflow = Phronomy::Workflow.define(context_class) do
      initial :step
      state :step
      transition from: :step, on: :finish, to: :__finish__
    end
    runtime = Phronomy::Runtime.instance
    expect(workflow.signal(workflow_instance_id: "missing", event: :finish)).to be(false)
    expect(runtime.__event_loop_if_initialized).to be_nil
    event_loop = runtime.event_loop
    event_loop.begin_draining
    expect(workflow.signal(workflow_instance_id: "missing", event: :finish)).to be(false)
    expect(Phronomy::WorkflowExecutionRegistry.existing_for(runtime)).to be_nil
  end

  it "waits across Agent admission before FSM creation and rejects a late invoke" do
    entered, release = Queue.new, Queue.new
    agent_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "agent-drain-boundary", version: 1
      model "local-model"
      instructions "Test"
      define_method(:extract_message) do |_input|
        entered << true
        release.pop
        raise ArgumentError, "known preparation failure"
      end
    end
    agent = agent_class.new
    task = agent.invoke_async("first")
    take(entered)
    runtime = Phronomy::Runtime.instance
    event_loop = runtime.event_loop
    stopping = Thread.new { runtime.shutdown(timeout: 3) }
    draining(event_loop)
    expect(stopping).to be_alive
    expect(event_loop).not_to be_idle
    expect { agent.invoke_async("late").wait_result(timeout: 3) }
      .to raise_error(Phronomy::RuntimeShutdownError)
    expect(entered).to be_empty
    release << true
    expect { task.wait_result(timeout: 3) }
      .to raise_error(ArgumentError, "known preparation failure")
    expect(Timeout.timeout(3) { stopping.value }).to be_cleanup_complete
  ensure
    release << true if release
    stopping&.join(3)
  end

  it "finishes an accepted Workflow load and terminal save while draining" do
    entered, release, writer_threads = Queue.new, Queue.new, Queue.new
    persistence = Phronomy::Persistence.in_memory
    repository = persistence.workflow_states
    allow(repository).to receive(:load).and_wrap_original do |original, *args|
      entered << true
      release.pop
      original.call(*args)
    end
    context_class = Class.new do
      include Phronomy::WorkflowContext

      field :value, type: :replace, default: 0
    end
    workflow = Phronomy::Workflow.define(context_class, persistence: persistence) do
      initial :step
      state :step
      entry :step, ->(context) {
        writer_threads << Phronomy::Runtime.in_event_loop_context?
        context.value += 1
      }
      transition from: :step, to: :__finish__
    end
    task = workflow.invoke_async({value: 4}, config: {workflow_instance_id: "draining"})
    take(entered)
    runtime = Phronomy::Runtime.instance
    event_loop = runtime.event_loop
    stopping = Thread.new { runtime.shutdown(timeout: 3) }
    draining(event_loop)
    expect(stopping).to be_alive
    expect(event_loop).not_to be_idle
    expect { workflow.invoke_async({}, config: {workflow_instance_id: "late"}).wait_result(timeout: 3) }
      .to raise_error(Phronomy::RuntimeShutdownError)
    expect(entered).to be_empty
    release << true
    expect(task.wait_result(timeout: 3).value).to eq(5)
    expect(take(writer_threads)).to be(true)
    expect(Timeout.timeout(3) { stopping.value }).to be_cleanup_complete
    allow(repository).to receive(:load).and_call_original
    expect(repository.load("draining").fetch(:snapshot).fetch("fields").fetch("value")).to eq(5)
  ensure
    release << true if release
    stopping&.join(3)
  end
end
