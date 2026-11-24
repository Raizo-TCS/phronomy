# frozen_string_literal: true

require "spec_helper"
require "timeout"

module WorkflowTerminalReconciliationSpec
  # The repository performs a real save before losing its first response. The
  # first readback fails independently; later operations use actual stored data.
  class FaultingRepository
    Gate = Struct.new(:entered, :release)

    attr_reader :save_error, :read_error

    def initialize(repository, commit:)
      @repository = repository
      @commit = commit
      @mutex = Mutex.new
      @save_calls = 0
      @load_calls = 0
      @save_error = IOError.new("terminal save response lost")
      @read_error = IOError.new("first terminal readback unavailable")
    end

    def load(id)
      error, gate = @mutex.synchronize do
        @load_calls += 1
        current = [@next_load_error, @next_load_gate]
        @next_load_error = @next_load_gate = nil
        current
      end
      raise error if error
      if gate
        gate.entered << true
        gate.release.pop
      end
      @repository.load(id)
    end

    def save(id, expected_revision:, snapshot:)
      first, gate = @mutex.synchronize do
        @save_calls += 1
        current = [@save_calls == 1, @next_save_gate]
        @next_save_gate = nil
        current
      end
      if gate
        gate.entered << true
        gate.release.pop
      end
      return @repository.save(id, expected_revision: expected_revision, snapshot: snapshot) unless first

      @repository.save(id, expected_revision: expected_revision, snapshot: snapshot) if @commit
      fail_next_load(@read_error)
      raise @save_error
    end

    def delete(id, expected_revision:)
      @repository.delete(id, expected_revision: expected_revision)
    end

    def fail_next_load(error)
      @mutex.synchronize { @next_load_error = error }
    end

    def block_next_load
      Gate.new(entered: Queue.new, release: Queue.new).tap do |gate|
        @mutex.synchronize { @next_load_gate = gate }
      end
    end

    def block_next_save
      Gate.new(entered: Queue.new, release: Queue.new).tap do |gate|
        @mutex.synchronize { @next_save_gate = gate }
      end
    end

    def counts
      @mutex.synchronize { {saves: @save_calls, loads: @load_calls} }
    end
  end
end

RSpec.describe "Workflow terminal reconciliation through Runtime" do
  def eventually
    Timeout.timeout(3) do
      loop do
        value = yield
        return value if value
        sleep 0.002
      end
    end
  end

  def take(queue)
    Timeout.timeout(3) { queue.pop }
  end

  def result_of(task)
    task.wait_result(timeout: 3)
  end

  def setup_workflow(commit: true, seed: false, task_based: false)
    @runtime = Phronomy::Runtime.instance
    @registry = Phronomy::WorkflowExecutionRegistry.for(@runtime.event_loop)
    @stored = Phronomy::PersistenceComposition.in_memory.workflow
    @id = "terminal-reconciliation-#{RSpec.current_example.metadata.fetch(:line_number)}"
    if seed
      @stored.save(@id, expected_revision: nil,
        snapshot: {fields: {value: 4, notes: ["captured"]}, phase: "waiting"})
    end
    @repository = WorkflowTerminalReconciliationSpec::FaultingRepository.new(@stored, commit: commit)
    @context_class = Class.new do
      include Phronomy::WorkflowContext

      field :value, default: 0
      field :notes, default: -> { ["captured"] }
    end
    actions = @actions = Queue.new
    @workflow = if task_based
      Phronomy::Workflow.define(@context_class, persistence: @repository) do
        initial :working
        task_state :working,
          start: ->(_) {
            actions << :start
            Phronomy::TaskResult.completed(9)
          },
          apply: ->(state, value) {
            actions << :apply
            state.merge(value: value)
          }
        transition from: :working, to: :__finish__
      end
    else
      Phronomy::Workflow.define(@context_class, persistence: @repository) do
        initial :waiting
        state :waiting
        state :done, action: ->(state) {
          actions << :done
          state.merge(value: state.value + 7)
        }
        transition from: :waiting, on: :finish, to: :done
      end
    end
    @sessions = Queue.new
    runner = @workflow.instance_variable_get(:@runner)
    allow(runner).to receive(:build_session_for).and_wrap_original do |build, **options|
      build.call(**options).tap { |session| @sessions << session }
    end
  end

  def start_unknown(task_based: false)
    @original = @workflow.invoke_async({}, config: {workflow_instance_id: @id})
    @session = take(@sessions)
    unless task_based
      eventually { @registry.workflow_admission_fsm_session_id(@id) == @session.id }
      expect(@workflow.signal(workflow_instance_id: @id, event: :finish)).to be(true)
    end
    await_original_unknown
  end

  def await_original_unknown
    error = nil
    expect { result_of(@original) }.to raise_error(Phronomy::WorkflowTerminalRecoveryError) { |caught| error = caught }
    @owner = @registry.workflow_admission_owner(@id)
    expect(@owner).not_to be_nil
    expect(error.workflow_instance_id).to eq(@id)
    expect(error.recovery_id).to eq(error.recovery.recovery_id)
    expect(@registry.workflow_admission_state(@id)).to eq(:recovery_required)
    expect(@registry.workflow_admission_fsm_session_id(@id)).to be_nil
    expect(@runtime.event_loop.admitted_fsm_session?(@session.id)).to be(false)
    @recovery_error = error
    @recovery = error.recovery
  end

  def reconcile
    result_of(@workflow.reconcile_terminal_async(recovery: @recovery))
  end

  def expect_retained(result, outcome:)
    expect(result.outcome).to eq(outcome)
    expect(result.application_state).to eq(:pending)
    expect(result.ownership_state).to eq(:retained)
    expect(@registry.workflow_admission_owner(@id)).to equal(@owner)
    expect(@original.status).to eq(:failed)
  end

  def block_reconciliation_read
    @repository.block_next_load.tap do |gate|
      (@gates ||= []) << gate
    end
  end

  def block_owner_then_fail
    gate = WorkflowTerminalReconciliationSpec::FaultingRepository::Gate.new(entered: Queue.new, release: Queue.new)
    (@gates ||= []) << gate
    receiver = Object.new
    receiver.define_singleton_method(:deliver_on_event_loop) do |_command|
      gate.entered << true
      gate.release.pop
      raise IOError, "injected owner failure after accepted delivery"
    end
    command = Struct.new(:runner).new(receiver)
    expect(@registry.post(command)).to be(true)
    take(gate.entered)
    gate
  end

  after do
    @gates&.each { |gate| gate.release << true }
    @stream_thread&.join(1)
    @stream_thread&.kill if @stream_thread&.alive?
    @stream_thread&.join(1)
    @shutdown_thread&.join(3)
    @runtime&.shutdown(timeout: 0.03, cancel_grace: 0.2)
  end

  it "reconciles a real commit through the retained owner without saving or running the graph again" do
    setup_workflow
    start_unknown
    expect(@stored.load(@id)[:snapshot].fetch("fields").fetch("value")).to eq(7)
    expect(@repository.counts).to eq(saves: 1, loads: 2)
    expect(@actions.size).to eq(1)
    expect(@runtime.event_loop.instance_variable_get(:@waiting)).not_to have_key(@session.id)
    expect(@workflow.pending_terminal_recovery(workflow_instance_id: @id)).to equal(@recovery)
    expect(@repository.counts).to eq(saves: 1, loads: 2)

    result = reconcile

    expect(result).to be_frozen
    expect(result.outcome).to eq(:confirmed_post)
    expect(result.application_state).to eq(:applied)
    expect(result.ownership_state).to eq(:released)
    expect(result.workflow_instance_id).to eq(@id)
    expect(result.recovery_id).to eq(@recovery.recovery_id)
    expect(result.revision).to eq(1)
    expect(result.context.value).to eq(7)
    expect(result.context.workflow_instance_id).to eq(@id)
    expect(result.context.phase).to eq(:__end__)
    expect(result.error).to be_nil
    expect(@registry.workflow_admission_owner(@id)).to be_nil
    expect(@workflow.pending_terminal_recovery(workflow_instance_id: @id)).to be_nil
    expect(@original.status).to eq(:failed)
    expect { result_of(@original) }.to raise_error { |error| expect(error).to equal(@recovery_error) }
    expect(@repository.counts).to eq(saves: 1, loads: 3)
    expect(@actions.size).to eq(1)
  end

  [false, true].each do |seed|
    it "reports confirmed non-commit from #{seed ? "the existing revision" : "initial absence"} without retrying the save" do
      setup_workflow(commit: false, seed: seed)
      start_unknown

      result = reconcile

      expect(result.outcome).to eq(:confirmed_pre)
      expect(result.application_state).to eq(:applied)
      expect(result.ownership_state).to eq(:released)
      expect(result.error).to equal(@repository.save_error)
      expect(result.context).to be_nil
      expect(@registry.workflow_admission_owner(@id)).to be_nil
      expect(@repository.counts).to eq(saves: 1, loads: 3)
      expect(@actions.size).to eq(1)
      if seed
        record = @stored.load(@id)
        expect(record[:revision]).to eq(1)
        expect(record[:snapshot].fetch("fields").fetch("value")).to eq(4)
      else
        expect(@stored.load(@id)).to be_nil
      end
    end
  end

  it "does not treat an identical snapshot at a later revision as this attempted commit" do
    setup_workflow
    start_unknown
    record = @stored.load(@id)
    @stored.save(@id, expected_revision: record[:revision], snapshot: record[:snapshot])

    result = reconcile

    expect_retained(result, outcome: :unresolved)
    expect(result.error).not_to be_nil
    expect(result.context).to be_nil
    expect(@repository.counts).to eq(saves: 1, loads: 3)
    competitor = @workflow.invoke_async({}, config: {workflow_instance_id: @id})
    expect { result_of(competitor) }.to raise_error(Phronomy::Error, /live execution segment/)
  end

  it "retains a failed read for a later explicit attempt without changing the original observation" do
    setup_workflow
    start_unknown
    @repository.fail_next_load(IOError.new("read still unavailable"))

    failed = reconcile
    expect_retained(failed, outcome: :unavailable)
    expect(failed.error).not_to be_nil
    resolved = reconcile

    expect(resolved.outcome).to eq(:confirmed_post)
    expect(resolved.ownership_state).to eq(:released)
    expect(failed.outcome).to eq(:unavailable)
    expect(failed.ownership_state).to eq(:retained)
    expect(@repository.counts).to eq(saves: 1, loads: 4)
  end

  it "joins concurrent observers to one physical read and ignores one observer's cancellation" do
    setup_workflow
    start_unknown
    gate = block_reconciliation_read
    first = @workflow.reconcile_terminal_async(recovery: @recovery)
    take(gate.entered)
    second = @workflow.reconcile_terminal_async(recovery: @recovery)
    expect(second).not_to equal(first)
    first.cancel!
    expect { result_of(first) }.to raise_error(Phronomy::CancellationError)
    expect(@registry.workflow_admission_owner(@id)).to equal(@owner)
    gate.release << true

    result = result_of(second)

    expect(result.outcome).to eq(:confirmed_post)
    expect(result.ownership_state).to eq(:released)
    expect(first.status).to eq(:cancelled)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
    expect(@actions.size).to eq(1)
  end

  it "does not start another physical read after a waiter-local timeout" do
    setup_workflow
    start_unknown
    gate = block_reconciliation_read
    first = @workflow.reconcile_terminal_async(recovery: @recovery)
    take(gate.entered)
    expect { first.wait_result(timeout: 0.01) }.to raise_error(Phronomy::TimeoutError)
    second = @workflow.reconcile_terminal_async(recovery: @recovery)
    gate.release << true

    expect(result_of(first).outcome).to eq(:confirmed_post)
    expect(result_of(second).outcome).to eq(:confirmed_post)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
  end

  it "reobserves a resolved receipt with a fresh context and no further persistence access" do
    setup_workflow
    start_unknown
    first = reconcile
    first.context.notes << "caller mutation"
    before = @repository.counts

    second = @workflow.reconcile_terminal(recovery: @recovery)

    expect(second).not_to equal(first)
    expect(second.context).not_to equal(first.context)
    expect(second.context.notes).to eq(["captured"])
    expect(second.outcome).to eq(:confirmed_post)
    expect(second.ownership_state).to eq(:released)
    expect(@repository.counts).to eq(before)
    expect(@actions.size).to eq(1)
  end

  it "preserves confirmed persistence when context construction fails and retries only missing application" do
    setup_workflow
    start_unknown
    failure = IOError.new("recovery context construction failed")
    allow(@context_class).to receive(:new).and_raise(failure)

    failed = reconcile

    expect_retained(failed, outcome: :confirmed_post)
    expect(failed.revision).to eq(1)
    expect(failed.context).to be_nil
    expect(failed.error).not_to be_nil
    expect(@repository.counts).to eq(saves: 1, loads: 3)
    allow(@context_class).to receive(:new).and_call_original
    resolved = reconcile

    expect(resolved.outcome).to eq(:confirmed_post)
    expect(resolved.application_state).to eq(:applied)
    expect(resolved.ownership_state).to eq(:released)
    expect(resolved.context.value).to eq(7)
    expect(failed.application_state).to eq(:pending)
    expect(failed.ownership_state).to eq(:retained)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
    expect(@actions.size).to eq(1)
  end

  it "does not reacquire released ownership when a repeated context view cannot be constructed" do
    setup_workflow
    start_unknown
    expect(reconcile.ownership_state).to eq(:released)
    allow(@context_class).to receive(:new).and_raise(IOError.new("context view unavailable"))

    failed = reconcile

    expect(failed.outcome).to eq(:confirmed_post)
    expect(failed.application_state).to eq(:applied)
    expect(failed.ownership_state).to eq(:released)
    expect(failed.context).to be_nil
    expect(failed.error).not_to be_nil
    expect(@registry.workflow_admission_owner(@id)).to be_nil
    allow(@context_class).to receive(:new).and_call_original
    expect(reconcile.context.value).to eq(7)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
  end

  it "keeps an old resolved receipt and old session sink from releasing a reused Workflow identity" do
    setup_workflow
    start_unknown
    expect(reconcile.ownership_state).to eq(:released)
    old_session = @session
    next_task = @workflow.invoke_async({}, config: {workflow_instance_id: @id})
    next_session = take(@sessions)
    eventually { @registry.workflow_admission_fsm_session_id(@id) == next_session.id }
    next_owner = @registry.workflow_admission_owner(@id)
    before = @repository.counts

    repeated = reconcile
    stale = Phronomy::WorkflowTerminalPersistence::Result.new(
      outcome: :known_failure, revision: nil, error: IOError.new("stale failure")
    )
    expect(old_session.event_sink.post(:workflow_terminal_persistence_result, stale)).to be(false)

    expect(repeated.outcome).to eq(:confirmed_post)
    expect(@registry.workflow_admission_owner(@id)).to equal(next_owner)
    expect(next_task.status).to eq(:pending)
    expect(@repository.counts).to eq(before)
    expect(@workflow.signal(workflow_instance_id: @id, event: :finish)).to be(true)
    expect(result_of(next_task).value).to eq(14)
  end

  it "rejects invalid and other-Workflow recovery capabilities before repository I/O" do
    setup_workflow
    start_unknown
    other = Phronomy::Workflow.define(@context_class, persistence: @repository) do
      initial :done
      state :done
    end
    before = @repository.counts

    expect { @workflow.reconcile_terminal(recovery: Object.new) }.to raise_error do |error|
      expect(error).to be_a(ArgumentError).or be_a(TypeError)
    end
    expect { other.reconcile_terminal(recovery: @recovery) }.to raise_error do |error|
      expect(error).to be_a(ArgumentError).or be_a(TypeError)
    end

    expect(@repository.counts).to eq(before)
    expect(reconcile.ownership_state).to eq(:released)
  end

  it "uses the same retained-error policy for a task-bearing Workflow without reentering its task" do
    setup_workflow(task_based: true)
    start_unknown(task_based: true)

    result = reconcile

    expect(result.outcome).to eq(:confirmed_post)
    expect(result.context.value).to eq(9)
    expect(result.ownership_state).to eq(:released)
    expect(@actions.size).to eq(2)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
    expect(@original.status).to eq(:failed)
  end

  it "returns a typed stream error and never calls the old stream block after reconciliation" do
    setup_workflow
    events = Queue.new
    returned = Queue.new
    @stream_thread = Thread.new do
      returned << @workflow.stream({}, config: {workflow_instance_id: @id}) { |event| events << event[:state] }
    rescue => error
      returned << error
    end
    @session = take(@sessions)
    expect(take(events)).to eq(:waiting)
    expect(@workflow.signal(workflow_instance_id: @id, event: :finish)).to be(true)
    error = take(returned)
    expect(error).to be_a(Phronomy::WorkflowTerminalRecoveryError)
    expect(@stream_thread.join(1)).to equal(@stream_thread)
    @recovery = error.recovery

    result = reconcile

    expect(result.context.value).to eq(7)
    expect(result.ownership_state).to eq(:released)
    expect(events.empty?).to be(true)
    expect(returned.empty?).to be(true)
    expect(@actions.size).to eq(1)
  end

  it "retains responsibility when recovery submission is rejected and permits a later explicit attempt" do
    setup_workflow
    start_unknown
    rejection = Phronomy::BackpressureError.new("recovery read rejected")
    allow(@runtime.offload).to receive(:submit) do |on_rejected: nil, **_options|
      on_rejected&.call(rejection)
      raise rejection
    end

    rejected = reconcile

    expect_retained(rejected, outcome: :unavailable)
    expect(@repository.counts).to eq(saves: 1, loads: 2)
    allow(@runtime.offload).to receive(:submit).and_call_original
    expect(reconcile.ownership_state).to eq(:released)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
  end

  it "reports incomplete shutdown and retains the capability without redirecting it to another Runtime" do
    setup_workflow
    start_unknown
    before = @repository.counts

    shutdown = @runtime.shutdown(timeout: 0.02, cancel_grace: 0.2)

    expect(shutdown.cleanup_complete?).to be(false)
    expect(@registry.workflow_admission_owner(@id)).to equal(@owner)
    unavailable = reconcile
    expect_retained(unavailable, outcome: :unavailable)
    expect(@repository.counts).to eq(before)
    expect(@runtime.shutdown(timeout: 0).cleanup_complete?).to be(false)
  end

  it "finishes an accepted recovery during drain before reporting complete shutdown" do
    setup_workflow
    start_unknown
    finished = Queue.new
    @shutdown_thread = Thread.new do
      finished << @runtime.shutdown(timeout: 2, cancel_grace: 0.2)
    end
    eventually { @runtime.state == :draining }

    result = reconcile

    expect(result.outcome).to eq(:confirmed_post)
    expect(result.ownership_state).to eq(:released)
    expect(take(finished).cleanup_complete?).to be(true)
    expect(@shutdown_thread.join(1)).to equal(@shutdown_thread)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
  end

  it "looks up missing recovery without starting the captured Runtime's dispatcher" do
    @runtime = Phronomy::Runtime.instance
    context_class = Class.new { include Phronomy::WorkflowContext }
    workflow = Phronomy::Workflow.define(context_class) do
      initial :done
      state :done
    end
    expect(@runtime.__event_loop_if_initialized).to be_nil

    expect(workflow.pending_terminal_recovery(workflow_instance_id: "never-started")).to be_nil

    expect(@runtime.__event_loop_if_initialized).to be_nil
  end

  it "discovers retained recovery after the original observer cancelled before receiving its error" do
    setup_workflow
    @original = @workflow.invoke_async({}, config: {workflow_instance_id: @id})
    @session = take(@sessions)
    eventually { @registry.workflow_admission_fsm_session_id(@id) == @session.id }
    @original.cancel!
    expect(@workflow.signal(workflow_instance_id: @id, event: :finish)).to be(true)
    @recovery = eventually { @workflow.pending_terminal_recovery(workflow_instance_id: @id) }
    eventually { @registry.workflow_admission_fsm_session_id(@id).nil? }
    before = @repository.counts

    result = reconcile

    expect(result.outcome).to eq(:confirmed_post)
    expect(result.ownership_state).to eq(:released)
    expect(@original.status).to eq(:cancelled)
    expect { result_of(@original) }.to raise_error(Phronomy::CancellationError)
    expect(@repository.counts).to eq(saves: 1, loads: before.fetch(:loads) + 1)
    expect(@actions.size).to eq(1)
  end

  it "retains the original save's physical boundary after an actual Offload timeout" do
    setup_workflow
    @original = @workflow.invoke_async({}, config: {workflow_instance_id: @id})
    @session = take(@sessions)
    eventually { @registry.workflow_admission_fsm_session_id(@id) == @session.id }
    pool = @runtime.offload
    allow(pool).to receive(:submit).and_wrap_original do |submit, **options, &work|
      submit.call(**options, timeout: 0.02, &work)
    end
    gate = @repository.block_next_save
    (@gates ||= []) << gate
    expect(@workflow.signal(workflow_instance_id: @id, event: :finish)).to be(true)
    take(gate.entered)
    eventually { pool.abandoned_active_count == 1 }
    await_original_unknown

    still_running = reconcile

    expect_retained(still_running, outcome: :unavailable)
    expect(@repository.counts).to eq(saves: 1, loads: 1)
    expect(@stored.load(@id)).to be_nil
    allow(pool).to receive(:submit).and_call_original
    gate.release << true
    eventually { pool.abandoned_active_count.zero? }
    expect(reconcile.outcome).to eq(:confirmed_post)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
    expect(@actions.size).to eq(1)
  end

  it "does not overlap recovery reads after an actual Offload timeout while the first worker still runs" do
    setup_workflow
    start_unknown
    pool = @runtime.offload
    allow(pool).to receive(:submit).and_wrap_original do |submit, **options, &work|
      submit.call(**options, timeout: 0.02, &work)
    end
    gate = block_reconciliation_read
    first = @workflow.reconcile_terminal_async(recovery: @recovery)
    take(gate.entered)
    eventually { pool.abandoned_active_count == 1 }
    second = @workflow.reconcile_terminal_async(recovery: @recovery)
    expect { first.wait_result(timeout: 0.01) }.to raise_error(Phronomy::TimeoutError)
    expect(@registry.workflow_admission_owner(@id)).to equal(@owner)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
    gate.release << true

    expect(result_of(first).outcome).to eq(:confirmed_post)
    expect(result_of(second).outcome).to eq(:confirmed_post)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
  end

  it "settles an accepted queued observation when its owner fails before dispatch" do
    setup_workflow
    start_unknown
    gate = block_owner_then_fail
    observer = @workflow.reconcile_terminal_async(recovery: @recovery)
    expect(observer.status).to eq(:pending)
    gate.release << true
    eventually { @runtime.state == :failed }

    result = result_of(observer)

    expect_retained(result, outcome: :unavailable)
    expect(@repository.counts).to eq(saves: 1, loads: 2)
  end

  it "settles a recovery observer when accepted Ready evidence is dropped by owner failure" do
    setup_workflow
    start_unknown
    read_gate = block_reconciliation_read
    observer = @workflow.reconcile_terminal_async(recovery: @recovery)
    take(read_gate.entered)
    owner_gate = block_owner_then_fail
    accepted = Queue.new
    allow(@registry).to receive(:post).and_wrap_original do |post, message, **options|
      post.call(message, **options).tap do |result|
        if result && message.is_a?(Phronomy::WorkflowTerminalOperation::Ready) && message.attempt_id
          accepted << message
        end
      end
    end
    read_gate.release << true
    take(accepted)
    expect(observer.status).to eq(:pending)
    owner_gate.release << true
    eventually { @runtime.state == :failed }

    result = result_of(observer)

    expect_retained(result, outcome: :unavailable)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
  end

  it "gives joined successful observers independent context views from one physical read" do
    setup_workflow
    start_unknown
    gate = block_reconciliation_read
    first = @workflow.reconcile_terminal_async(recovery: @recovery)
    take(gate.entered)
    second = @workflow.reconcile_terminal_async(recovery: @recovery)
    gate.release << true

    first_result = result_of(first)
    second_result = result_of(second)

    expect(second_result).not_to equal(first_result)
    expect(second_result.context).not_to equal(first_result.context)
    first_result.context.notes << "first observer mutation"
    expect(second_result.context.notes).to eq(["captured"])
    expect(first_result.ownership_state).to eq(:released)
    expect(second_result.ownership_state).to eq(:released)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
  end

  it "requires accepted completion custody after an adopter throws following its retention intent" do
    setup_workflow
    attempts = Queue.new
    first_adoption = true
    allow(@registry).to receive(:adopt_retirement).and_wrap_original do |adopt, retirement|
      acceptance = adopt.call(retirement)
      attempts << retirement
      if first_adoption
        first_adoption = false
        raise IOError, "adoption failed before returning acceptance"
      end
      acceptance
    end
    @original = @workflow.invoke_async({}, config: {workflow_instance_id: @id})
    @session = take(@sessions)
    eventually { @registry.workflow_admission_fsm_session_id(@id) == @session.id }
    expect(@workflow.signal(workflow_instance_id: @id, event: :finish)).to be(true)
    first_retirement = take(attempts)
    @recovery = eventually { @workflow.pending_terminal_recovery(workflow_instance_id: @id) }
    @owner = @registry.workflow_admission_owner(@id)
    expect(@original.status).to eq(:pending)
    expect(@runtime.event_loop.instance_variable_get(:@waiting)).to have_key(@session.id)

    not_adopted = reconcile

    expect(not_adopted.outcome).to eq(:unavailable)
    expect(not_adopted.ownership_state).to eq(:retained)
    expect(@repository.counts).to eq(saves: 1, loads: 2)
    expect(take(attempts)).to equal(first_retirement)
    expect { result_of(@original) }.to raise_error(Phronomy::WorkflowTerminalRecoveryError)
    expect(@registry.workflow_admission_owner(@id)).to equal(@owner)
    expect(reconcile.ownership_state).to eq(:released)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
  end

  it "retains completed evidence when Ready delivery is refused and applies it on the next observation" do
    setup_workflow
    start_unknown
    allow(@registry).to receive(:post).and_wrap_original do |post, message, **options|
      if message.is_a?(Phronomy::WorkflowTerminalOperation::Ready) && message.attempt_id
        false
      else
        post.call(message, **options)
      end
    end

    refused = reconcile

    expect_retained(refused, outcome: :unavailable)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
    allow(@registry).to receive(:post).and_call_original
    result = reconcile
    expect(result.outcome).to eq(:confirmed_post)
    expect(result.ownership_state).to eq(:released)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
    expect(@actions.size).to eq(1)
  end

  it "retains terminal evidence when its original session sink refuses delivery" do
    setup_workflow
    @original = @workflow.invoke_async({}, config: {workflow_instance_id: @id})
    @session = take(@sessions)
    eventually { @registry.workflow_admission_fsm_session_id(@id) == @session.id }
    sink = @session.event_sink
    allow(sink).to receive(:post).and_wrap_original do |post, type, payload = nil|
      (type == :workflow_terminal_persistence_result) ? false : post.call(type, payload)
    end
    expect(@workflow.signal(workflow_instance_id: @id, event: :finish)).to be(true)
    expect { result_of(@original) }.to raise_error(Phronomy::WorkflowTerminalRecoveryError)
    @recovery = eventually { @workflow.pending_terminal_recovery(workflow_instance_id: @id) }
    eventually { @registry.workflow_admission_fsm_session_id(@id).nil? }
    allow(sink).to receive(:post).and_call_original

    result = reconcile

    expect(result.outcome).to eq(:confirmed_post)
    expect(result.ownership_state).to eq(:released)
    expect(result.context.value).to eq(7)
    expect(@runtime.event_loop.instance_variable_get(:@waiting)).not_to have_key(@session.id)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
    expect(@actions.size).to eq(1)
  end

  it "propagates a non-StandardError from reconciliation without discarding its owner" do
    setup_workflow
    start_unknown
    failure = Exception.new("non-StandardError from persistence read")
    @repository.fail_next_load(failure)
    observer = @workflow.reconcile_terminal_async(recovery: @recovery)

    expect { result_of(observer) }.to raise_error { |error| expect(error).to equal(failure) }

    expect(@registry.workflow_admission_owner(@id)).to equal(@owner)
    expect(@workflow.pending_terminal_recovery(workflow_instance_id: @id)).to equal(@recovery)
    expect(@original.status).to eq(:failed)
    expect(reconcile.ownership_state).to eq(:released)
    expect(@repository.counts).to eq(saves: 1, loads: 4)
  end

  it "retains an admitted save when its completion callback registration raises" do
    setup_workflow
    @original = @workflow.invoke_async({}, config: {workflow_instance_id: @id})
    @session = take(@sessions)
    eventually { @registry.workflow_admission_fsm_session_id(@id) == @session.id }
    gate = @repository.block_next_save
    (@gates ||= []) << gate
    admitted = Queue.new
    registration_error = IOError.new("save completion registration failed after admission")
    environment = @workflow.instance_variable_get(:@runner).instance_variable_get(:@environment)
    allow(environment).to receive(:submit).and_wrap_original do |submit, **options, &work|
      submit.call(**options, &work).tap do |task|
        allow(task).to receive(:on_complete).and_raise(registration_error)
        admitted << task
      end
    end
    expect(@workflow.signal(workflow_instance_id: @id, event: :finish)).to be(true)
    task = take(admitted)
    take(gate.entered)
    eventually { @registry.workflow_admission_fsm_session_id(@id).nil? }
    await_original_unknown

    blocked = reconcile

    expect_retained(blocked, outcome: :unavailable)
    expect(task.physical_complete?).to be(false)
    expect(@repository.counts).to eq(saves: 1, loads: 1)
    expect(admitted.empty?).to be(true)
    expect(@stored.load(@id)).to be_nil
    allow(environment).to receive(:submit).and_call_original
    gate.release << true
    eventually { task.physical_complete? }
    result = reconcile
    expect(result.outcome).to eq(:confirmed_post)
    expect(result.ownership_state).to eq(:released)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
    expect(@actions.size).to eq(1)
  end

  it "retains an admitted recovery read when its completion callback registration raises" do
    setup_workflow
    start_unknown
    gate = block_reconciliation_read
    admitted = Queue.new
    registration_error = IOError.new("read completion registration failed after admission")
    environment = @workflow.instance_variable_get(:@runner).instance_variable_get(:@environment)
    allow(environment).to receive(:submit).and_wrap_original do |submit, **options, &work|
      submit.call(**options, &work).tap do |task|
        allow(task).to receive(:on_complete).and_raise(registration_error)
        admitted << task
      end
    end
    observer = @workflow.reconcile_terminal_async(recovery: @recovery)
    task = take(admitted)
    take(gate.entered)

    refused = result_of(observer)

    expect_retained(refused, outcome: :unavailable)
    expect(task.physical_complete?).to be(false)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
    second = @workflow.reconcile_terminal_async(recovery: @recovery)
    expect { second.wait_result(timeout: 0.01) }.to raise_error(Phronomy::TimeoutError)
    expect(admitted.empty?).to be(true)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
    gate.release << true
    eventually { task.physical_complete? }
    result = result_of(second)
    expect(result.outcome).to eq(:confirmed_post)
    expect(result.ownership_state).to eq(:released)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
    expect(admitted.empty?).to be(true)
    expect(@actions.size).to eq(1)
  end

  it "polls an admitted read whose physical callback registration failed without stranding another observer" do
    setup_workflow
    start_unknown
    gate = block_reconciliation_read
    admitted = Queue.new
    registration_error = IOError.new("physical read completion registration failed")
    environment = @workflow.instance_variable_get(:@runner).instance_variable_get(:@environment)
    allow(environment).to receive(:submit).and_wrap_original do |submit, **options, &work|
      submit.call(**options, &work).tap do |task|
        allow(task).to receive(:on_physical_complete).and_raise(registration_error)
        admitted << task
      end
    end
    first = @workflow.reconcile_terminal_async(recovery: @recovery)
    task = take(admitted)
    take(gate.entered)
    expect_retained(result_of(first), outcome: :unavailable)
    expect(task.physical_complete?).to be(false)

    second = @workflow.reconcile_terminal_async(recovery: @recovery)

    expect_retained(result_of(second), outcome: :unavailable)
    expect(admitted.empty?).to be(true)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
    gate.release << true
    eventually { task.physical_complete? }
    result = reconcile
    expect(result.outcome).to eq(:confirmed_post)
    expect(result.ownership_state).to eq(:released)
    expect(admitted.empty?).to be(true)
    expect(@repository.counts).to eq(saves: 1, loads: 3)
    expect(@actions.size).to eq(1)
    expect(@original.status).to eq(:failed)
  end
end
