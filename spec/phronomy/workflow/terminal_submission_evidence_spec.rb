# frozen_string_literal: true

require "spec_helper"
require "timeout"

# All admission, worker execution and persistence use the real Runtime.
# The custom submit fault only loses a real accepted handle; the built-in pool
# does not intentionally implement this fault.
RSpec.describe "Workflow terminal submission evidence through Runtime" do
  def eventually
    Timeout.timeout(4) do
      loop do
        value = yield
        return value if value
        sleep 0.002
      end
    end
  end

  def take(queue) = Timeout.timeout(4) { queue.pop }

  def setup_workflow(size: 1, queue: 10)
    Phronomy.configure do |configuration|
      configuration.offload_pool_size = size
      configuration.offload_queue_size = queue
    end
    @runtime = Phronomy::Runtime.instance
    @registry = Phronomy::WorkflowExecutionRegistry.for(@runtime.event_loop)
    @stored = Phronomy::PersistenceComposition.in_memory.workflow
    @context = Class.new do
      include Phronomy::WorkflowContext

      field :value, default: 0
    end
    @workflow = Phronomy::Workflow.define(@context, persistence: @stored) do
      initial :waiting
      state :waiting
      transition from: :waiting, on: :finish, to: :__finish__
    end
    @id = "admission-evidence-#{RSpec.current_example.metadata.fetch(:line_number)}"
    @original = @workflow.invoke_async({}, config: {workflow_instance_id: @id})
    @fsm_id = eventually { @registry.workflow_admission_fsm_session_id(@id) }
    @owner = @registry.workflow_admission_owner(@id)
  end

  def await_error(task)
    task.wait_result(timeout: 4)
    raise "Expected an error"
  rescue Phronomy::Error, IOError, NoMethodError => error
    error
  end

  def block_pool_worker
    entered = Queue.new
    release = Queue.new
    (@releases ||= []) << release
    task = @runtime.offload.submit do
      entered << true
      release.pop
    end
    take(entered)
    [task, release]
  end

  after do
    @releases&.each { |release| release << true }
    @runtime&.shutdown(timeout: 0.02, cancel_grace: 0.2)
  end

  it "retains a queued save with a lost handle before worker entry and after late completion" do
    setup_workflow
    blocker, release = block_pool_worker
    fault = IOError.new("accepted terminal submit response lost before worker entry")
    hidden = nil
    allow(@runtime.offload).to receive(:submit).and_wrap_original do |submit, **options, &operation|
      next submit.call(**options, &operation) if hidden
      hidden = submit.call(**options, &operation)
      raise fault
    end
    @workflow.signal(workflow_instance_id: @id, event: :finish)
    error = await_error(@original)
    expect(error).to be_a(Phronomy::WorkflowTerminalRecoveryError)
    expect(error.original_error).to equal(fault)
    expect(hidden.physical_complete?).to be(false)
    expect(@registry.workflow_admission_owner(@id)).to equal(@owner)
    expect(@workflow.pending_terminal_recovery(workflow_instance_id: @id)).to equal(error.recovery)
    allow(@runtime.offload).to receive(:submit).and_call_original
    competitor = @workflow.invoke_async({}, config: {workflow_instance_id: @id})
    expect(await_error(competitor).message).to include("live execution segment")
    blocked = @workflow.reconcile_terminal_async(recovery: error.recovery).wait_result(timeout: 4)
    expect(blocked.outcome).to eq(:unavailable)
    expect(blocked.ownership_state).to eq(:retained)
    release << true
    blocker.wait_result(timeout: 4)
    expect(hidden.wait_result(timeout: 4).outcome).to eq(:success)
    eventually { hidden.physical_complete? }
    expect(@stored.load(@id)[:revision]).to eq(1)
    late = @workflow.reconcile_terminal_async(recovery: error.recovery).wait_result(timeout: 4)
    expect(late.outcome).to eq(:unavailable)
    expect(late.ownership_state).to eq(:retained)
    expect(@registry.workflow_admission_owner(@id)).to equal(@owner)
    expect(@original.status).to eq(:failed)
    expect(@runtime.shutdown(timeout: 0.02, cancel_grace: 0.2).cleanup_complete?).to be(false)
  end

  [false, true].each do |false_refusal|
    it "retains an entered hidden save even with refusal evidence #{false_refusal}" do
      setup_workflow(size: 2)
      entered = Queue.new
      release = Queue.new
      (@releases ||= []) << release
      first_save = true
      allow(@stored).to receive(:save).and_wrap_original do |save, *arguments, **options|
        if first_save
          first_save = false
          entered << true
          release.pop
        end
        save.call(*arguments, **options)
      end
      fault = IOError.new("accepted terminal submit response lost after worker entry")
      hidden = nil
      allow(@runtime.offload).to receive(:submit).and_wrap_original do |submit, **options, &operation|
        next submit.call(**options, &operation) if hidden
        hidden = submit.call(**options, &operation)
        take(entered)
        options[:on_rejected]&.call(fault) if false_refusal
        raise fault
      end
      @workflow.signal(workflow_instance_id: @id, event: :finish)
      error = await_error(@original)
      expect(error).to be_a(Phronomy::WorkflowTerminalRecoveryError)
      expect(error.original_error).to equal(fault)
      expect(hidden.physical_complete?).to be(false)
      expect(@registry.workflow_admission_owner(@id)).to equal(@owner)
      expect(@stored.load(@id)).to be_nil
      allow(@runtime.offload).to receive(:submit).and_call_original
      competitor = @workflow.invoke_async({}, config: {workflow_instance_id: @id})
      expect(await_error(competitor).message).to include("live execution segment")
      release << true
      expect(hidden.wait_result(timeout: 4).outcome).to eq(:success)
      eventually { hidden.physical_complete? }
      expect(@stored.load(@id)[:revision]).to eq(1)
      late = @workflow.reconcile_terminal_async(recovery: error.recovery).wait_result(timeout: 4)
      expect(late.outcome).to eq(:unavailable)
      expect(late.ownership_state).to eq(:retained)
      expect(@registry.workflow_admission_owner(@id)).to equal(@owner)
      expect(@original.status).to eq(:failed)
    end
  end

  it "preserves ordinary failure and release after actual full-pool refusal" do
    setup_workflow(queue: 1)
    blocker, release = block_pool_worker
    queued = @runtime.offload.submit { :queued_work }
    @workflow.signal(workflow_instance_id: @id, event: :finish)
    error = await_error(@original)
    expect(error).to be_a(Phronomy::BackpressureError)
    expect(@registry.workflow_admission_owner(@id)).to be_nil
    expect(@stored.load(@id)).to be_nil
    release << true
    blocker.wait_result(timeout: 4)
    queued.wait_result(timeout: 4)
  end

  [false, true].each do |raise_on_submit|
    it "keeps the legacy explicit-keyword environment contract when raising is #{raise_on_submit}" do
      setup_workflow
      environment = @workflow.instance_variable_get(:@runner).instance_variable_get(:@environment)
      pool = @runtime.offload
      calls = 0
      fault = IOError.new("legacy submit did not report admission evidence")
      environment.singleton_class.undef_method(:supports_submission_rejection?)
      environment.define_singleton_method(:submit) do |on_full: :raise, &operation|
        calls += 1
        raise fault if raise_on_submit
        pool.submit(on_full: on_full, &operation)
      end
      @workflow.signal(workflow_instance_id: @id, event: :finish)
      if raise_on_submit
        error = await_error(@original)
        expect(error).to be_a(Phronomy::WorkflowTerminalRecoveryError)
        expect(error.original_error).to equal(fault)
        expect(@registry.workflow_admission_owner(@id)).to equal(@owner)
        observation = @workflow.reconcile_terminal_async(recovery: error.recovery).wait_result(timeout: 4)
        expect(observation.outcome).to eq(:unavailable)
        expect(@stored.load(@id)).to be_nil
      else
        expect(@original.wait_result(timeout: 4).value).to eq(0)
        expect(@registry.workflow_admission_owner(@id)).to be_nil
        expect(@stored.load(@id)[:revision]).to eq(1)
      end
      expect(calls).to eq(1)
    end
  end

  it "keeps a returned task over contradictory refusal and recovers after physical callback binding fails" do
    setup_workflow
    blocker, release = block_pool_worker
    fault = IOError.new("physical callback registration failed")
    admitted = Queue.new
    environment = @workflow.instance_variable_get(:@runner).instance_variable_get(:@environment)
    allow(environment).to receive(:submit).and_wrap_original do |submit, **options, &operation|
      submit.call(**options, &operation).tap do |task|
        options[:on_rejected]&.call(fault)
        allow(task).to receive(:on_physical_complete).and_raise(fault)
        admitted << task
      end
    end
    @workflow.signal(workflow_instance_id: @id, event: :finish)
    task = take(admitted)
    error = await_error(@original)
    expect(error).to be_a(Phronomy::WorkflowTerminalRecoveryError)
    expect(@registry.workflow_admission_owner(@id)).to equal(@owner)
    blocked = @workflow.reconcile_terminal_async(recovery: error.recovery).wait_result(timeout: 4)
    expect(blocked.outcome).to eq(:unavailable)
    expect(task.physical_complete?).to be(false)
    release << true
    blocker.wait_result(timeout: 4)
    task.wait_result(timeout: 4)
    eventually { task.physical_complete? }
    resolved = @workflow.reconcile_terminal_async(recovery: error.recovery).wait_result(timeout: 4)
    expect(resolved.outcome).to eq(:confirmed_post)
    expect(resolved.ownership_state).to eq(:released)
    expect(admitted.empty?).to be(true)
    expect(@original.status).to eq(:failed)
  end

  [:raise, :nil].each do |lost_response|
    it "retains a reconciliation handle lost through #{lost_response} without another read" do
      setup_workflow(size: 2)
      lose_readback = false
      block_next_read = false
      entered = Queue.new
      release = Queue.new
      (@releases ||= []) << release
      reads = 0
      allow(@stored).to receive(:save).and_wrap_original do |save, *arguments, **options|
        save.call(*arguments, **options)
        lose_readback = true
        raise IOError, "terminal save response lost"
      end
      allow(@stored).to receive(:load).and_wrap_original do |load, *arguments|
        if lose_readback
          lose_readback = false
          raise IOError, "first readback unavailable"
        end
        reads += 1
        if block_next_read
          block_next_read = false
          entered << true
          release.pop
        end
        load.call(*arguments)
      end
      @workflow.signal(workflow_instance_id: @id, event: :finish)
      original_error = await_error(@original)
      expect(original_error).to be_a(Phronomy::WorkflowTerminalRecoveryError)
      recovery = original_error.recovery
      eventually { @registry.workflow_admission_state(@id) == :recovery_required }
      expect(@registry.workflow_admission_owner(@id)).to equal(@owner)
      block_next_read = true
      hidden = nil
      fault = IOError.new("accepted reconciliation submit response lost")
      allow(@runtime.offload).to receive(:submit).and_wrap_original do |submit, **options, &operation|
        next submit.call(**options, &operation) if hidden
        hidden = submit.call(**options, &operation)
        take(entered)
        raise fault if lost_response == :raise
        nil
      end
      first = @workflow.reconcile_terminal_async(recovery: recovery).wait_result(timeout: 4)
      expect(first.outcome).to eq(:unavailable)
      expect(first.ownership_state).to eq(:retained)
      expect(hidden.physical_complete?).to be(false)
      allow(@runtime.offload).to receive(:submit).and_call_original
      second = @workflow.reconcile_terminal_async(recovery: recovery).wait_result(timeout: 4)
      expect(second.outcome).to eq(:unavailable)
      expect(second.ownership_state).to eq(:retained)
      expect(hidden.physical_complete?).to be(false)
      expect(@registry.workflow_admission_owner(@id)).to equal(@owner)
      expect(reads).to eq(1)
      release << true
      hidden.wait_result(timeout: 4)
      eventually { hidden.physical_complete? }
      late = @workflow.reconcile_terminal_async(recovery: recovery).wait_result(timeout: 4)
      expect(late.outcome).to eq(:unavailable)
      expect(late.ownership_state).to eq(:retained)
      expect(reads).to eq(1)
      expect(@registry.workflow_admission_owner(@id)).to equal(@owner)
      expect(@original.status).to eq(:failed)
    end
  end
end
