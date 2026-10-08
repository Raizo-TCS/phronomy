# frozen_string_literal: true

require "spec_helper"
require "open3"
require "timeout"

RSpec.describe "Workflow execution ownership" do
  let(:runtime) { Phronomy::Runtime.new }
  let(:other_runtime) { Phronomy::Runtime.new }
  let(:context_class) do
    Class.new do
      include Phronomy::WorkflowContext

      field :value, default: 0
    end
  end

  before do
    Phronomy::WorkflowExecutionEnvironment.install_provider(-> { Phronomy::WorkflowEngineEnvironment.new(runtime: runtime) })
  end

  after do
    Phronomy::WorkflowExecutionEnvironment.install_provider(-> { Phronomy::WorkflowEngineEnvironment.new })
    runtime.shutdown(timeout: 1)
    other_runtime.shutdown(timeout: 1)
  end

  def take(queue)
    Timeout.timeout(3) { queue.pop }
  end

  def change_default
    allow(Phronomy::Runtime).to receive(:instance).and_return(other_runtime)
    Phronomy::WorkflowExecutionEnvironment.install_provider(-> { Phronomy::WorkflowEngineEnvironment.new(runtime: other_runtime) })
  end

  def workflow(persistence: nil, entered: Queue.new)
    Phronomy::Workflow.define(context_class, persistence: persistence) do
      initial :waiting
      state :waiting, action: ->(context) {
        entered << Thread.current
        context
      }
      transition from: :waiting, on: :finish, to: :__finish__,
        action: ->(context, event) { context.merge(value: event.payload.fetch(:value)) }
    end
  end

  it "runs Workflow callback rules without loading Engine or state_machines" do
    source = <<~RUBY
      require "phronomy/execution/task_result"
      require "phronomy/workflow/execution/workflow_action_rules"
      rules = Phronomy::WorkflowActionRules
      context = Object.new
      context.define_singleton_method(:set_graph_metadata) {}
      abort unless rules.allowed?(->(c, e) { c.equal?(context) && e == :finish }, context, :finish)
      abort unless rules.entry(->(c) { c }, context, :start).equal?(context)
      abort unless rules.transition(->(c, e) { nil }, context, :finish, metadata: {}).equal?(context)
      abort if defined?(Phronomy::Runtime) || defined?(Phronomy::FSMSession) || defined?(StateMachines)
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", source)
    expect(status.success?).to be(true), output
  end

  it "compiles and looks up a missing execution without creating Runtime resources" do
    expect(runtime).not_to receive(:offload)
    compiled = workflow
    expect(compiled.signal(workflow_instance_id: "absent", event: :finish)).to be(false)
    expect(runtime.__event_loop_if_initialized).to be_nil
  end

  it "retains its owner across load, signal, terminal save and release when defaults change" do
    entered = Queue.new
    load_entered, release_load = Queue.new, Queue.new
    save_entered, release_save = Queue.new, Queue.new
    store = Phronomy::PersistenceComposition.in_memory.workflow
    repository = Object.new
    repository.define_singleton_method(:load) do |id|
      load_entered << Thread.current
      release_load.pop
      store.load(id)
    end
    repository.define_singleton_method(:save) do |id, **options|
      save_entered << Thread.current
      release_save.pop
      store.save(id, **options)
    end
    repository.define_singleton_method(:delete) { |id, **options| store.delete(id, **options) }
    compiled = workflow(persistence: repository, entered: entered)
    task = compiled.invoke_async({}, config: {workflow_instance_id: "owned"})
    load_thread = take(load_entered)
    change_default
    expect(other_runtime).not_to receive(:event_loop)
    release_load << true
    owner_thread = take(entered)
    expect(owner_thread).not_to be(load_thread)
    expect(compiled.signal(workflow_instance_id: "owned", event: :finish, payload: {value: 7})).to be(true)
    expect(take(save_entered)).not_to be(owner_thread)
    registry = Phronomy::WorkflowExecutionRegistry.existing_for(runtime)
    expect(registry.workflow_admission_state("owned")).to eq(:persisting_terminal)
    expect(task).not_to be_done
    release_save << true
    expect(task.wait_result(timeout: 3).value).to eq(7)
    expect(store.load("owned")[:snapshot]["fields"]["value"]).to eq(7)
    expect(registry.workflow_admission_owner("owned")).to be_nil
    expect(other_runtime.__event_loop_if_initialized).to be_nil
  ensure
    release_load << true if release_load
    release_save << true if release_save
  end

  it "rejects work on a stopped owner instead of adopting a replacement Runtime" do
    compiled = workflow
    runtime.shutdown(timeout: 1)
    change_default
    task = compiled.invoke_async({}, config: {workflow_instance_id: "stopped"})
    expect { task.wait_result(timeout: 3) }.to raise_error(Phronomy::RuntimeShutdownError)
    expect(compiled.signal(workflow_instance_id: "stopped", event: :finish)).to be(false)
    expect(other_runtime.__event_loop_if_initialized).to be_nil
  end
end
