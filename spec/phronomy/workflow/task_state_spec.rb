# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe "Workflow task_state" do
  let(:context_class) do
    Class.new do
      include Phronomy::WorkflowContext

      field :value, default: 0
      field :values, default: -> { [] }
    end
  end
  let(:registry) { Phronomy::WorkflowExecutionRegistry.for(Phronomy::Runtime.instance.event_loop) }

  def take(queue)
    Timeout.timeout(3) { queue.pop }
  end

  def result(task)
    task.wait_result(timeout: 3)
  end

  def graph(source = nil, start: nil, apply: nil, persistence: nil, &extra)
    start ||= ->(_context) { source }
    apply ||= ->(context, value) { context.merge(value: value) }
    Phronomy::Workflow.define(context_class, persistence: persistence) do
      initial :working
      task_state :working, start: start, apply: apply
      transition from: :working, to: :__finish__
      instance_exec(&extra) if extra
    end
  end

  it "applies an already-complete result before evaluating ordinary guards" do
    app = graph(Phronomy::TaskResult.completed(7))
    expect(app.invoke({}).value).to eq(7)
  end

  it "waits without using an Offload worker and applies on EventLoop" do
    source = Phronomy::TaskResult.deferred
    entered = Queue.new
    owner = nil
    app = graph(start: ->(_snapshot) {
      entered << Thread.current
      source
    },
      apply: ->(context, value) {
        owner = Thread.current
        context.merge(value: value)
      })
    runtime = Phronomy::Runtime.instance
    allow(runtime).to receive(:offload).and_call_original
    task = app.invoke_async({})
    entry_thread = take(entered)
    expect(task.status).to eq(:pending)
    expect(runtime).not_to have_received(:offload)
    source.complete(9)
    expect(result(task).value).to eq(9)
    expect(owner).to equal(entry_thread)
    expect(owner).not_to equal(Thread.current)
  end

  it "isolates the start snapshot from the context given to apply" do
    snapshot = nil
    app = graph(start: ->(state) {
      snapshot = state
      state.values << :start
      Phronomy::TaskResult.completed(8)
    },
      apply: ->(state, value) {
        expect(state).not_to equal(snapshot)
        expect(state.values).to eq([])
        state.merge(value: value)
      })
    expect(app.invoke({}).value).to eq(8)
    expect(snapshot.phase).to eq(:working)
  end

  it "accepts nil from apply as no context replacement" do
    expect(graph(Phronomy::TaskResult.completed(7), apply: ->(_c, _v) {}).invoke({value: 2}).value).to eq(2)
  end

  it "completes a task state with no outgoing transition only after apply" do
    source, entered = Phronomy::TaskResult.deferred, Queue.new
    app = Phronomy::Workflow.define(context_class) do
      task_state :last, start: ->(_) {
        entered << true
        source
      },
        apply: ->(state, value) { state.merge(value: value) }
    end
    task = app.invoke_async({})
    take(entered)
    expect(task.status).to eq(:pending)
    source.complete(4)
    expect(result(task).value).to eq(4)
  end

  it "collects two answers on two entries into the same state" do
    app = Phronomy::Workflow.define(context_class) do
      initial :asking
      task_state :asking, start: ->(state) { Phronomy::TaskResult.completed(state.values.length + 1) },
        apply: ->(state, value) { state.merge(values: state.values + [value]) }
      state :decide
      transition from: :asking, to: :decide
      transition from: :decide, to: :__finish__, guard: ->(state) { state.values.length == 2 }
      transition from: :decide, to: :asking
    end
    expect(app.invoke({}).values).to eq([1, 2])
  end

  %i[success failure cancelled].each do |kind|
    it "ignores an old #{kind} after an external transition re-enters the same state" do
      sources, entered = [], Queue.new
      app = graph(start: ->(_) {
        Phronomy::TaskResult.deferred.tap { |t|
          sources << t
          entered << true
        }
      }) do
        transition from: :working, on: :again, to: :working
      end
      task = app.invoke_async({}, config: {workflow_instance_id: "again"})
      take(entered)
      app.signal(workflow_instance_id: "again", event: :again)
      take(entered)
      case kind
      when :success then sources[0].complete(99)
      when :failure then sources[0].fail(IOError.new("stale"))
      when :cancelled then sources[0].cancel!
      end
      sources[1].complete(3)
      expect(result(task).value).to eq(3)
    end
  end

  it "ignores duplicate completion even when an observer was already copied for delivery" do
    source, entered, applications = Phronomy::TaskResult.deferred, Queue.new, []
    app = graph(start: ->(_) {
      entered << true
      source
    },
      apply: ->(state, value) {
        applications << value
        state.merge(value: value)
      })
    task = app.invoke_async({})
    take(entered)
    callback = source.instance_variable_get(:@on_complete_callbacks).first
    source.complete(5)
    callback.call(88, nil)
    expect(result(task).value).to eq(5)
    expect(applications).to eq([5])
  end

  it "does not send an old result to a later execution with the same durable ID" do
    sources, entered = [], Queue.new
    app = graph(start: ->(_) {
      Phronomy::TaskResult.deferred.tap { |t|
        sources << t
        entered << true
      }
    }) do
      transition from: :working, on: :stop, to: :__finish__
    end
    first = app.invoke_async({}, config: {workflow_instance_id: "reuse"})
    take(entered)
    app.signal(workflow_instance_id: "reuse", event: :stop)
    result(first)
    second = app.invoke_async({}, config: {workflow_instance_id: "reuse"})
    take(entered)
    sources[0].fail(IOError.new("previous execution"))
    sources[1].complete(6)
    expect(result(second).value).to eq(6)
  end

  %i[start source apply].each do |stage|
    it "preserves the original #{stage} error and releases admission" do
      error = IOError.new(stage.to_s)
      source = Phronomy::TaskResult.failed(error)
      app = case stage
      when :start then graph(start: ->(_) { raise error })
      when :source then graph(source)
      when :apply then graph(Phronomy::TaskResult.completed(1), apply: ->(_c, _v) { raise error })
      end
      task = app.invoke_async({}, config: {workflow_instance_id: "failure"})
      expect { result(task) }.to raise_error { |caught| expect(caught).to equal(error) }
      expect(task.status).to eq(:failed)
      expect(registry.workflow_admission_owner("failure")).to be_nil
    end
  end

  it "distinguishes a cancelled source from a failed CancellationError" do
    error = Phronomy::CancellationError.new("cancel")
    source = Phronomy::TaskResult.deferred
    source.cancel!(error)
    cancelled = graph(source).invoke_async({})
    expect { result(cancelled) }.to raise_error { |caught| expect(caught).to equal(error) }
    expect(cancelled.status).to eq(:cancelled)
    failed = graph(Phronomy::TaskResult.failed(error)).invoke_async({})
    expect { result(failed) }.to raise_error { |caught| expect(caught).to equal(error) }
    expect(failed.status).to eq(:failed)
  end

  [nil, 7, Object.new].each do |invalid|
    it "rejects a non-TaskResult start value #{invalid.class}" do
      expect { graph(start: ->(_) { invalid }).invoke({}) }.to raise_error(TypeError, /start must return/)
    end
  end

  [7, {}, Phronomy::TaskResult.completed(1)].each do |invalid|
    it "rejects a non-context apply value #{invalid.class}" do
      expect { graph(Phronomy::TaskResult.completed(1), apply: ->(_c, _v) { invalid }).invoke({}) }
        .to raise_error(TypeError, /apply must return/)
    end
  end

  it "makes explicit parent cancellation observable without cancelling the source" do
    source, entered = Phronomy::TaskResult.deferred, Queue.new
    token = Phronomy::Concurrency::CancellationToken.new
    app = graph(start: ->(_) {
      entered << true
      source
    })
    task = app.invoke_async({}, config: {workflow_instance_id: "cancel", cancellation_token: token})
    take(entered)
    token.cancel!
    expect { result(task) }.to raise_error(Phronomy::CancellationError)
    expect(task.status).to eq(:cancelled)
    expect(source.status).to eq(:pending)
    expect(registry.workflow_admission_owner("cancel")).to be_nil
    source.complete(55)
    expect(task.status).to eq(:cancelled)
  end

  it "does not call start for a pre-cancelled parent" do
    token = Phronomy::Concurrency::CancellationToken.new.cancel!
    start = double("start")
    expect(start).not_to receive(:call)
    allow(start).to receive(:respond_to?).with(:call).and_return(true)
    task = graph(start: start).invoke_async({}, config: {cancellation_token: token})
    expect { result(task) }.to raise_error(Phronomy::CancellationError)
    expect(task.status).to eq(:cancelled)
  end

  it "promotes the parent's deadline on the Workflow's owner runtime" do
    source = Phronomy::TaskResult.deferred
    token = Phronomy::Concurrency::CancellationToken.timeout_after(0.03)
    task = graph(source).invoke_async({}, config: {cancellation_token: token})
    expect { result(task) }.to raise_error(Phronomy::CancellationError)
    expect(task.status).to eq(:cancelled)
    expect(source.status).to eq(:pending)
  end

  it "reports a rejected current completion instead of leaving the caller pending" do
    source, entered = Phronomy::TaskResult.deferred, Queue.new
    app = graph(start: ->(_) {
      entered << true
      source
    })
    task = app.invoke_async({}, config: {workflow_instance_id: "rejected"})
    take(entered)
    allow(registry).to receive(:post).and_wrap_original do |original, command, **options|
      command.is_a?(Phronomy::WorkflowTaskReception::Notification) ? false : original.call(command, **options)
    end
    source.complete(5)
    expect { result(task) }.to raise_error(Phronomy::RuntimeShutdownError, /rejected/)
    expect(registry.workflow_admission_owner("rejected")).to be_nil
  end

  it "preserves a transport exception through owner-side failure delivery" do
    source, entered = Phronomy::TaskResult.deferred, Queue.new
    error = IOError.new("delivery broke")
    app = graph(start: ->(_) {
      entered << true
      source
    })
    task = app.invoke_async({})
    take(entered)
    allow(registry).to receive(:post).and_wrap_original do |original, command, **options|
      raise error if command.is_a?(Phronomy::WorkflowTaskReception::Notification)
      original.call(command, **options)
    end
    source.complete(5)
    expect { result(task) }.to raise_error { |caught| expect(caught).to equal(error) }
  end

  it "settles pending task observation and cleans up on Runtime shutdown" do
    source, entered = Phronomy::TaskResult.deferred, Queue.new
    app = graph(start: ->(_) {
      entered << true
      source
    })
    task = app.invoke_async({}, config: {workflow_instance_id: "shutdown"})
    take(entered)
    expect(Phronomy::Runtime.instance.shutdown(timeout: 1).cleanup_complete?).to be(true)
    expect { result(task) }.to raise_error(Phronomy::RuntimeShutdownError)
    expect(source.status).to eq(:pending)
  end

  it "revokes callback references when leaving a never-ending source" do
    source, entered = Phronomy::TaskResult.deferred, Queue.new
    app = graph(start: ->(_) {
      entered << true
      source
    }) do
      transition from: :working, on: :stop, to: :__finish__
    end
    task = app.invoke_async({}, config: {workflow_instance_id: "references"})
    take(entered)
    callback = source.instance_variable_get(:@on_complete_callbacks).first
    reception = callback.binding.receiver
    expect(reception).to be_a(Phronomy::WorkflowTaskReception)
    app.signal(workflow_instance_id: "references", event: :stop)
    result(task)
    expect(reception.instance_variable_get(:@registry)).to be_nil
    expect(reception.instance_variable_get(:@source)).to be_nil
    expect(registry.instance_variable_get(:@task_executions)).to be_empty
  end

  it "saves normal task completion through the existing durable barrier" do
    store = Phronomy::PersistenceComposition.in_memory.workflow
    app = graph(Phronomy::TaskResult.completed(8), persistence: store)
    expect(app.invoke({}, config: {workflow_instance_id: "saved"}).value).to eq(8)
    expect(store.load("saved")[:snapshot]["phase"]).to eq("__end__")
    expect(store.load("saved")[:snapshot]["fields"]["value"]).to eq(8)
  end

  it "resumes a durable ordinary wait into a new task state" do
    store = Phronomy::PersistenceComposition.in_memory.workflow
    app = Phronomy::Workflow.define(context_class, persistence: store) do
      initial :approval
      wait_state :approval
      task_state :working, start: ->(_) { Phronomy::TaskResult.completed(3) },
        apply: ->(state, value) { state.merge(value: value) }
      transition from: :approval, on: :approved, to: :working
      transition from: :working, to: :__finish__
    end
    halted = app.invoke({}, config: {workflow_instance_id: "approval"})
    expect(halted.phase).to eq(:approval)
    expect(app.resume(state: halted).value).to eq(3)
    expect(store.load("approval")[:revision]).to eq(2)
  end

  it "rejects restart of a pending task snapshot without rerunning side effects" do
    store = Phronomy::PersistenceComposition.in_memory.workflow
    store.save("pending", expected_revision: nil, snapshot: {fields: {value: 1, values: []}, phase: "working"})
    start = double("start", call: Phronomy::TaskResult.completed(1))
    expect(start).not_to receive(:call)
    app = graph(start: start, persistence: store)
    expect { app.invoke({}, config: {workflow_instance_id: "pending"}) }
      .to raise_error(Phronomy::WorkflowTaskResumeError) { |e| expect(e.code).to eq("workflow.task_resume_unsupported") }
    state = context_class.new(value: 1)
    state.set_graph_metadata(workflow_instance_id: "pending", phase: :working)
    expect { app.resume(state: state) }.to raise_error(Phronomy::WorkflowTaskResumeError)
    expect(store.load("pending")[:revision]).to eq(1)
  end

  it "reports an unknown durable outcome while retaining recovery-required ownership" do
    store = Phronomy::PersistenceComposition.in_memory.workflow
    app = graph(Phronomy::TaskResult.completed(9), persistence: store)
    allow(store).to receive(:save).and_raise(IOError, "commit uncertain")
    allow(store).to receive(:load).and_return(nil, {revision: 8, snapshot: {fields: {value: 99}, phase: "__end__"}})
    task = app.invoke_async({}, config: {workflow_instance_id: "uncertain"})
    expect { result(task) }.to raise_error(Phronomy::Persistence::StateConflictError)
    expect(registry.workflow_admission_owner("uncertain")).not_to be_nil
    expect(task.status).to eq(:failed)
  end

  it "does not apply queued automatic completion to a re-entered task state" do
    sources, entered, applied = [], Queue.new, Queue.new
    gate = Queue.new
    app = graph(start: ->(_) {
      Phronomy::TaskResult.deferred.tap { |t|
        sources << t
        entered << true
      }
    },
      apply: ->(state, value) {
        applied << true
        gate.pop
        state.merge(value: value)
      }) do
      transition from: :working, on: :again, to: :working
    end
    task = app.invoke_async({}, config: {workflow_instance_id: "queued"})
    take(entered)
    sources[0].complete(1)
    take(applied)
    app.signal(workflow_instance_id: "queued", event: :again)
    gate << true
    take(entered)
    # This accepted event is a FIFO barrier behind the old automatic completion.
    # It re-enters once more, making any erroneous early terminalization observable.
    app.signal(workflow_instance_id: "queued", event: :again)
    take(entered)
    expect(task.status).to eq(:pending)
    sources[2].complete(7)
    take(applied)
    gate << true
    expect(result(task).value).to eq(7)
  ensure
    gate << true if gate
  end

  it "keeps a current source when an external guard rejects its transition" do
    source, entered = Phronomy::TaskResult.deferred, Queue.new
    app = graph(start: ->(_) {
      entered << true
      source
    }) do
      transition from: :working, on: :stop, to: :__finish__, guard: ->(_) { false }
    end
    task = app.invoke_async({}, config: {workflow_instance_id: "guard"})
    take(entered)
    app.signal(workflow_instance_id: "guard", event: :stop)
    source.complete(4)
    expect(result(task).value).to eq(4)
  end

  it "does not expose private task completion as a business signal" do
    source, entered = Phronomy::TaskResult.deferred, Queue.new
    app = graph(start: ->(_) {
      entered << true
      source
    })
    task = app.invoke_async({}, config: {workflow_instance_id: "private"})
    take(entered)
    expect { app.signal(workflow_instance_id: "private", event: :state_completed) }.to raise_error(ArgumentError)
    source.complete(2)
    expect(result(task).value).to eq(2)
  end

  it "settles observation without releasing ownership when all delivery is unavailable" do
    source, entered = Phronomy::TaskResult.deferred, Queue.new
    app = graph(start: ->(_) {
      entered << true
      source
    })
    task = app.invoke_async({}, config: {workflow_instance_id: "unavailable"})
    take(entered)
    allow(registry).to receive(:post).and_return(false)
    source.complete(2)
    expect { result(task) }.to raise_error(Phronomy::RuntimeShutdownError)
    expect(registry.workflow_admission_owner("unavailable")).not_to be_nil
    allow(registry).to receive(:post).and_call_original
    expect(Phronomy::Runtime.instance.shutdown(timeout: 1).cleanup_complete?).to be(true)
  end

  it "ignores delivery failure from an already revoked reception" do
    sources, entered = [], Queue.new
    app = graph(start: ->(_) {
      Phronomy::TaskResult.deferred.tap { |t|
        sources << t
        entered << true
      }
    }) do
      transition from: :working, on: :again, to: :working
    end
    task = app.invoke_async({}, config: {workflow_instance_id: "stale-delivery"})
    take(entered)
    receipt = sources.first.instance_variable_get(:@on_complete_callbacks).first.binding.receiver
    app.signal(workflow_instance_id: "stale-delivery", event: :again)
    take(entered)
    registry.task_delivery_failed(receipt, IOError.new("late transport failure"))
    sources.last.complete(6)
    expect(result(task).value).to eq(6)
  end

  it "keeps cancellation delivery on the runtime that owns the Workflow" do
    source, entered = Phronomy::TaskResult.deferred, Queue.new
    token = Phronomy::Concurrency::CancellationToken.new
    owner = Phronomy::Runtime.instance
    app = graph(start: ->(_) {
      entered << true
      source
    })
    task = app.invoke_async({}, config: {cancellation_token: token})
    take(entered)
    other = Phronomy::Runtime.new
    Phronomy::Runtime.restore_default_for_test(other)
    token.cancel!
    expect { result(task) }.to raise_error(Phronomy::CancellationError)
    expect(source.status).to eq(:pending)
  ensure
    other&.shutdown(timeout: 1)
    Phronomy::Runtime.restore_default_for_test(owner) if owner
  end

  it "rejects an invalid cancellation token without leaking admission" do
    task = graph(Phronomy::TaskResult.completed(1)).invoke_async({},
      config: {workflow_instance_id: "invalid-token", cancellation_token: Object.new})
    expect { result(task) }.to raise_error(TypeError, /cancellation_token/)
    expect(registry.workflow_admission_owner("invalid-token")).to be_nil
  end

  it "rejects duplicate or conflicting task declarations" do
    start, apply = ->(_) { Phronomy::TaskResult.completed(1) }, ->(_c, _v) {}
    expect {
      Phronomy::Workflow.define(context_class) {
        state :x
        task_state :x, start: start, apply: apply
      }
    }
      .to raise_error(ArgumentError, /already declared/)
    expect {
      Phronomy::Workflow.define(context_class) {
        task_state :x, start: start, apply: apply
        wait_state :x
      }
    }
      .to raise_error(ArgumentError, /already declared/)
  end
end
