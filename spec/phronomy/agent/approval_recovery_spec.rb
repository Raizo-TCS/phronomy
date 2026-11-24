# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe "Standalone approval recovery through the original Runtime" do
  def take(queue)
    Timeout.timeout(4) { queue.pop }
  end

  def eventually
    Timeout.timeout(4) do
      loop do
        value = yield
        return value if value
        sleep 0.002
      end
    end
  end

  def result_of(task)
    task.wait_result(timeout: 4)
  end

  def gate
    {entered: Queue.new, release: Queue.new}.tap { |value| (@gates ||= []) << value }
  end

  def occupy_full_pool
    eventually { @runtime.offload.active_count.zero? && @runtime.offload.queue_depth.zero? }
    waiting = gate
    occupied = @runtime.offload.submit(on_full: :raise) do
      waiting.fetch(:entered) << true
      waiting.fetch(:release).pop
    end
    take(waiting.fetch(:entered))
    queued = @runtime.offload.submit(on_full: :raise) { :filler }
    expect(@runtime.offload.queue_depth).to eq(1)
    [waiting, occupied, queued]
  end

  def empty_pool(waiting, occupied, queued)
    waiting.fetch(:release) << true
    result_of(occupied)
    result_of(queued)
    eventually { @runtime.offload.active_count.zero? && @runtime.offload.queue_depth.zero? }
  end

  def on_owner(&action)
    result = Phronomy::TaskResult.deferred(name: "approval-recovery-observation")
    handler = Object.new
    handler.define_singleton_method(:deliver_on_event_loop) do |_message|
      result.complete(action.call)
    rescue => error
      result.fail(error)
    end
    @registry.post(Struct.new(:coordinator).new(handler), completion: result)
    result_of(result)
  end

  # Provider and Tool behavior is deterministic; admission, waits, transactions,
  # session resumption and shutdown all run through the real Runtime.
  def setup_wait(children: 1, second_batch: false, tool_gate: nil, pool_size: nil)
    @calls, @effects, @events = [], [], []
    calls, effects, events = @calls, @effects, @events
    @approvals = notifications = Queue.new
    tool = Class.new(Phronomy::Tool::Base) do
      tool_name "recovered_approval_read"
      description "Read exactly once after approval"
      requires_approval true
      param :item, type: :string, desc: "Read identity"
      define_method(:execute) do |item:|
        effects << item
        if tool_gate
          tool_gate.fetch(:entered) << item
          tool_gate.fetch(:release).pop
        end
        "read #{item}"
      end
    end
    @agent_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "approval-recovery-runtime", version: 1
      model "offline-model"
      tools tool => nil
    end
    @adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |request, cancellation_token:|
        cancellation_token&.raise_if_cancelled!
        calls << request
        if calls.size == 1 || (second_batch && calls.size == 2)
          batch = calls.size
          Phronomy::LLMAdapter::Response.new(finish_reason: :tool_calls,
            tool_calls: children.times.map do |index|
              Phronomy::Tool::CallRequest.new(id: "batch-#{batch}-#{index}",
                name: "recovered_approval_read", arguments: {item: "#{batch}:#{index}"})
            end)
        else
          Phronomy::LLMAdapter::Response.new(content: "approved answer", finish_reason: :stop)
        end
      end
    end.new
    Phronomy.configure do |configuration|
      configuration.llm_adapter = @adapter
      if pool_size
        configuration.offload_pool_size = pool_size
        configuration.offload_queue_size = 1
      end
    end
    @store = Phronomy::PersistenceComposition.in_memory.agent
    @agent = @agent_class.create(agent_id: "approval-recovery-#{RSpec.current_example.metadata.fetch(:line_number)}",
      persistence: @store, on_event: ->(event) {
        events << event
        notifications << event.payload.fetch(:request) if event.type == :approval_required
      })
    @token = Phronomy::Concurrency::CancellationToken.new
    @original = @agent.invoke_async("read", config: {cancellation_token: @token})
    @request = take(@approvals)
    @runtime = Phronomy::Runtime.instance
    @registry = Phronomy::Agent::ExecutionRegistry.for(@runtime.event_loop)
    @environment = @agent.__execution_environment
    @coordinator = on_owner { @registry.agent_execution_state(@request.execution_id).coordinator }
    @before = durable_snapshot
    expect(@calls.size).to eq(1)
    expect(@effects).to be_empty
    expect(live_snapshot).to include(status: :suspended, phase: :approval,
      admission: :suspended, cancellation_binding: true)
  end

  def durable_snapshot
    [@store.agents.load(@agent.agent_id).to_h,
      @store.executions.load(@request.execution_id).to_h]
  end

  def live_snapshot
    on_owner do
      state = @registry.agent_execution_state(@request.execution_id)
      admission = @registry.instance_variable_get(:@agent_admissions)[@agent.agent_id]
      {status: state.execution.status, phase: state.execution.phase,
       revision: state.execution.execution_revision, root_revision: @agent.agent_root.agent_revision,
       request_id: state.execution.approval_request&.fetch("id"), admission: admission&.state,
       cancellation_binding: !@coordinator.instance_variable_get(:@suspended_cancellation).nil?}
    end
  end

  def install_write_fault(mode)
    @fault = IOError.new("approval #{mode}")
    @writes = 0
    armed = true
    allow(@store).to receive(:transaction).and_wrap_original do |original, &transaction|
      next original.call(&transaction) unless armed
      armed = false
      @writes += 1
      if mode == :pre
        original.call do |*arguments|
          transaction.call(*arguments)
          raise @fault
        end
      else
        original.call(&transaction)
        raise @fault
      end
    end
  end

  def start_unknown(mode: :post, approved: true)
    install_write_fault(mode)
    @decision = @agent.approve_async(@request.execution_id,
      approval_request_id: @request.id, approved: approved)
    await_unknown(approved: approved)
  end

  def await_unknown(approved: true)
    expect { result_of(@decision) }.to raise_error(Phronomy::Agent::ApprovalRecoveryError) do |error|
      @decision_error = error
      @recovery = error.recovery
    end
    expect(@recovery.agent_id).to eq(@agent.agent_id)
    expect(@recovery.execution_id).to eq(@request.execution_id)
    expect(@recovery.approval_request_id).to eq(@request.id)
    expect(@recovery.approved).to be(approved)
    expect(@agent.pending_approval_recovery(execution_id: @request.execution_id)).to equal(@recovery)
    expect(@registry.agent_execution_admitted?(@agent.agent_id)).to be(true)
    expect(@calls.size).to eq(1)
    expect(@effects).to be_empty
  end

  def reconcile
    result_of(@agent.reconcile_approval_async(recovery: @recovery))
  end

  def expect_pending(receipt, outcome:, physical: true)
    expect(receipt.outcome).to eq(outcome)
    expect(receipt.application_state).to eq(:pending)
    expect(receipt.continuation_state).to eq(:pending)
    expect(receipt.resolved?).to be(false)
    expect(receipt.physical_complete?).to be(physical)
    expect(@agent.pending_approval_recovery(execution_id: @request.execution_id)).to equal(@recovery)
    expect(@effects).to be_empty
    expect(@calls.size).to eq(1)
  end

  def expect_retired
    operation = @recovery.send(:operation)
    references = on_owner do
      %i[agent coordinator environment command request invocation continuation_plan
        suspended_cancellation].map { |name| operation.public_send(name) }
    end
    expect(references).to all(be_nil)
  end

  def expect_restored(receipt)
    expect(receipt.outcome).to eq(:confirmed_pre)
    expect(receipt.application_state).to eq(:applied)
    expect(receipt.continuation_state).to eq(:restored)
    expect(receipt.resolved?).to be(true)
    expect(receipt.physical_complete?).to be(true)
    expect(receipt.execution_task).to be_nil
    expect(@agent.pending_approval_recovery(execution_id: @request.execution_id)).to be_nil
    expect_retired
  end

  def expect_resumed(receipt)
    expect(receipt.outcome).to eq(:confirmed_post)
    expect(receipt.application_state).to eq(:applied)
    expect(receipt.continuation_state).to eq(:resumed)
    expect(receipt.resolved?).to be(true)
    expect(receipt.physical_complete?).to be(true)
    expect(receipt.execution_task).to respond_to(:wait_result)
    expect(@agent.pending_approval_recovery(execution_id: @request.execution_id)).to be_nil
    expect_retired
  end

  after do
    @gates&.each { |waiting| 4.times { waiting.fetch(:release) << true } }
    @runtime&.shutdown(timeout: 0.03, cancel_grace: 0.2)
  end

  it "keeps ordinary successful approval behavior and needs no recovery capability" do
    setup_wait
    decision = @agent.approve_async(@request.execution_id, approval_request_id: @request.id)

    expect(result_of(decision).fetch(:output)).to eq("approved answer")
    expect(result_of(@original).fetch(:output)).to eq("approved answer")
    expect(@agent.pending_approval_recovery(execution_id: @request.execution_id)).to be_nil
    expect(@effects).to eq(["1:0"])
    expect(@calls.size).to eq(2)
  end

  [true, false].each do |approved|
    it "reconciles committed approved=#{approved} exactly once without reopening the failed decision observer" do
      setup_wait
      start_unknown(approved: approved)
      durable = @store.executions.load(@request.execution_id)
      expect(durable.status).to eq(:active)
      expect(durable.phase).to eq(:resuming)
      expect(durable.approval_request.fetch("approved")).to be(approved)
      expect(durable.execution_revision).to eq(@before.last.fetch("execution_revision") + 1)
      expect(live_snapshot).to include(status: :suspended, admission: :recovery_required,
        cancellation_binding: false)
      repeated = @agent.approve_async(@request.execution_id, approval_request_id: @request.id)
      expect { result_of(repeated) }.to raise_error(Phronomy::AgentBusyError)

      receipt = reconcile

      expect_resumed(receipt)
      answer = result_of(receipt.execution_task)
      expect(result_of(@original)).to eq(answer)
      if approved
        expect(answer.fetch(:output)).to eq("approved answer")
        expect(@effects).to eq(["1:0"])
        expect(@calls.size).to eq(2)
      else
        expect(answer.fetch(:rejected)).to be(true)
        expect(@effects).to be_empty
        expect(@calls.size).to eq(1)
      end
      again = reconcile
      expect_resumed(again)
      expect(again.revision).to eq(receipt.revision)
      expect(again.execution_task).not_to equal(receipt.execution_task)
      expect(result_of(again.execution_task)).to eq(answer)
      expect(@writes).to eq(1)
      expect { result_of(@decision) }.to raise_error { |error| expect(error).to equal(@decision_error) }
    end
  end

  it "restores exact pre-state and its cancellation binding, then requires a fresh explicit approval" do
    setup_wait
    start_unknown(mode: :pre)
    expect(durable_snapshot).to eq(@before)

    receipt = reconcile

    expect_restored(receipt)
    expect(durable_snapshot).to eq(@before)
    expect(live_snapshot).to include(status: :suspended, phase: :approval,
      admission: :suspended, request_id: @request.id, cancellation_binding: true)
    expect(@effects).to be_empty
    expect(@calls.size).to eq(1)
    fresh = @agent.approve_async(@request.execution_id, approval_request_id: @request.id)
    expect(result_of(fresh).fetch(:output)).to eq("approved answer")
    expect(result_of(@original).fetch(:output)).to eq("approved answer")
    expect(@effects).to eq(["1:0"])
    expect(@calls.size).to eq(2)
    expect_restored(reconcile)
    expect(@effects).to eq(["1:0"])
  end

  it "honors cancellation already requested while a rolled back decision was uncertain" do
    setup_wait
    start_unknown(mode: :pre)
    @token.cancel!
    expect(live_snapshot).to include(admission: :recovery_required, cancellation_binding: false)

    expect_restored(reconcile)

    expect { result_of(@original) }.to raise_error(Phronomy::CancellationError)
    expect(@effects).to be_empty
    expect(@calls.size).to eq(1)
    expect(@store.executions.load(@request.execution_id).status).to eq(:cancelled)
  end

  it "retains unknown proof after a read failure and accepts a later explicit observation" do
    setup_wait
    start_unknown
    allow(@store.coordinator).to receive(:atomic).and_raise(IOError, "authoritative read unavailable")

    expect_pending(reconcile, outcome: :unavailable)
    expect(@writes).to eq(1)
    allow(@store.coordinator).to receive(:atomic).and_call_original
    receipt = reconcile
    expect_resumed(receipt)
    expect(result_of(receipt.execution_task).fetch(:output)).to eq("approved answer")
    expect(@effects).to eq(["1:0"])
    expect(@calls.size).to eq(2)
  end

  it "does not treat a divergent durable decision as authority for continuation" do
    setup_wait
    start_unknown
    committed = @store.executions.load(@request.execution_id)
    divergent = committed.with(approval_request: committed.approval_request.merge("approved" => false))
    @store.transaction do |records|
      records.executions.save(@request.execution_id,
        expected_revision: committed.execution_revision, execution: divergent)
    end

    expect_pending(reconcile, outcome: :unresolved)

    expect(@store.executions.load(@request.execution_id).approval_request.fetch("approved")).to be(false)
    expect(@writes).to eq(1)
  end

  it "rejects foreign and malformed capabilities without reading persistence" do
    setup_wait
    start_unknown
    expect(@store.coordinator).not_to receive(:atomic)

    expect { @agent.dup.reconcile_approval_async(recovery: @recovery) }.to raise_error(ArgumentError)
    expect { @agent.reconcile_approval(recovery: Object.new) }.to raise_error(ArgumentError)
    expect(@agent.dup.pending_approval_recovery(execution_id: @request.execution_id)).to be_nil
  end

  it "coalesces simultaneous read observers without cancellation propagating to the owned read" do
    setup_wait
    start_unknown
    waiting = gate
    reads = 0
    allow(Phronomy::Agent::ApprovalPersistenceEvidence)
      .to receive(:read).and_wrap_original do |original, **options|
      reads += 1
      if reads == 1
        waiting.fetch(:entered) << true
        waiting.fetch(:release).pop
      end
      original.call(**options)
    end
    first = @agent.reconcile_approval_async(recovery: @recovery)
    take(waiting.fetch(:entered))
    second = @agent.reconcile_approval_async(recovery: @recovery)
    first.cancel!
    on_owner { true }
    waiting.fetch(:release) << true

    receipt = result_of(second)
    expect_resumed(receipt)
    expect { result_of(first) }.to raise_error(Phronomy::CancellationError)
    expect(reads).to eq(1)
    expect(result_of(receipt.execution_task).fetch(:output)).to eq("approved answer")
    expect(@effects).to eq(["1:0"])
    expect(@calls.size).to eq(2)
  end

  it "does not cancel canonical business continuation when a fresh execution observer is cancelled" do
    waiting = gate
    setup_wait(tool_gate: waiting)
    start_unknown
    receipt = reconcile
    expect_resumed(receipt)
    take(waiting.fetch(:entered))
    receipt.execution_task.cancel!
    expect { result_of(receipt.execution_task) }.to raise_error(Phronomy::CancellationError)
    again = reconcile
    expect(again.execution_task).not_to equal(receipt.execution_task)
    waiting.fetch(:release) << true

    expect(result_of(again.execution_task).fetch(:output)).to eq("approved answer")
    expect(result_of(@original).fetch(:output)).to eq("approved answer")
    expect(@effects).to eq(["1:0"])
    expect(@calls.size).to eq(2)
  end

  it "does not let a resolved capability approve the next approval request" do
    setup_wait(second_batch: true)
    start_unknown
    first_receipt = reconcile
    expect_resumed(first_receipt)
    second_request = take(@approvals)
    expect(second_request.id).not_to eq(@request.id)
    expect(@calls.size).to eq(2)
    expect(@effects).to eq(["1:0"])

    repeated = reconcile
    expect_resumed(repeated)
    expect(live_snapshot).to include(status: :suspended, request_id: second_request.id)
    expect(@effects).to eq(["1:0"])
    rejected = @agent.approve_async(second_request.execution_id,
      approval_request_id: @request.id, approved: true)
    expect { result_of(rejected) }.to raise_error(ArgumentError)
    fresh = @agent.approve_async(second_request.execution_id,
      approval_request_id: second_request.id, approved: false)
    expect(result_of(fresh).fetch(:rejected)).to be(true)
    expect(result_of(first_receipt.execution_task).fetch(:rejected)).to be(true)
    expect(@effects).to eq(["1:0"])
  end

  it "restores the same wait after actual full-pool approval-save rejection without retaining recovery" do
    setup_wait(pool_size: 1)
    waiting, occupied, queued = occupy_full_pool
    decision = @agent.approve_async(@request.execution_id, approval_request_id: @request.id)

    expect { result_of(decision) }.to raise_error(Phronomy::BackpressureError)

    expect(decision.physical_complete?).to be(true)
    expect(durable_snapshot).to eq(@before)
    expect(live_snapshot).to include(status: :suspended, phase: :approval,
      admission: :suspended, request_id: @request.id, cancellation_binding: true)
    expect(@agent.pending_approval_recovery(execution_id: @request.execution_id)).to be_nil
    expect(@effects).to be_empty
    expect(@calls.size).to eq(1)
    empty_pool(waiting, occupied, queued)
    fresh = @agent.approve_async(@request.execution_id, approval_request_id: @request.id)
    expect(result_of(fresh).fetch(:output)).to eq("approved answer")
    expect(result_of(@original).fetch(:output)).to eq("approved answer")
    expect(@effects).to eq(["1:0"])
    expect(@calls.size).to eq(2)
  end

  it "allows a fresh explicit read after actual full-pool reconciliation rejection" do
    setup_wait(pool_size: 1)
    start_unknown
    reads = 0
    allow(Phronomy::Agent::ApprovalPersistenceEvidence).to receive(:read).and_wrap_original do |original, **options|
      reads += 1
      original.call(**options)
    end
    waiting, occupied, queued = occupy_full_pool

    2.times { expect_pending(reconcile, outcome: :unavailable) }

    expect(reads).to eq(0)
    expect(@writes).to eq(1)
    empty_pool(waiting, occupied, queued)
    receipt = reconcile
    expect_resumed(receipt)
    expect(result_of(receipt.execution_task).fetch(:output)).to eq("approved answer")
    expect(reads).to eq(1)
    expect(@effects).to eq(["1:0"])
    expect(@calls.size).to eq(2)
  end

  it "retains a write whose accepted submission lost its handle even after the hidden worker completes" do
    setup_wait
    waiting = gate
    accepted = Queue.new
    submissions = 0
    allow(@environment).to receive(:submit).and_wrap_original do |original, **options, &work|
      submissions += 1
      original.call(**options) do
        waiting.fetch(:entered) << true
        waiting.fetch(:release).pop
        work.call
      end.tap { |task| accepted << task }
      raise IOError, "accepted approval submission lost its handle"
    end
    @decision = @agent.approve_async(@request.execution_id, approval_request_id: @request.id)
    hidden = take(accepted)
    take(waiting.fetch(:entered))
    await_unknown

    expect_pending(reconcile, outcome: :unavailable, physical: false)
    expect(submissions).to eq(1)
    waiting.fetch(:release) << true
    eventually { hidden.physical_complete? }
    expect_pending(reconcile, outcome: :unavailable, physical: false)
    expect(submissions).to eq(1)
    expect(@runtime.shutdown(timeout: 0.02, cancel_grace: 0.02).cleanup_complete?).to be(false)
    expect(@agent.pending_approval_recovery(execution_id: @request.execution_id)).to equal(@recovery)
  end

  it "keeps accepted approval-save custody after callback registration fails until the worker is quiet" do
    setup_wait
    waiting = gate
    admitted = Queue.new
    submissions = 0
    allow(@environment).to receive(:submit).and_wrap_original do |original, **options, &work|
      submissions += 1
      original.call(**options) do
        waiting.fetch(:entered) << true
        waiting.fetch(:release).pop
        work.call
      end.tap do |task|
        allow(task).to receive(:on_complete).and_raise(IOError, "approval save callback registration failed")
        admitted << task
      end
    end
    @decision = @agent.approve_async(@request.execution_id, approval_request_id: @request.id)
    worker = take(admitted)
    take(waiting.fetch(:entered))
    await_unknown

    expect_pending(reconcile, outcome: :unavailable, physical: false)
    expect(@decision.physical_complete?).to be(false)
    expect(submissions).to eq(1)
    allow(@environment).to receive(:submit).and_call_original
    waiting.fetch(:release) << true
    eventually { worker.physical_complete? }
    receipt = reconcile

    expect_resumed(receipt)
    expect(@decision.physical_complete?).to be(true)
    expect(result_of(receipt.execution_task).fetch(:output)).to eq("approved answer")
    expect(@effects).to eq(["1:0"])
    expect(@calls.size).to eq(2)
  end

  it "retries interrupted live application without repeating the decision write or authorized Tool" do
    setup_wait
    start_unknown
    replace_calls = 0
    allow(@agent).to receive(:__replace_root).and_wrap_original do |original, root|
      replace_calls += 1
      result = original.call(root)
      raise IOError, "live root applied but application response was lost" if replace_calls == 1
      result
    end

    partial = reconcile

    expect(partial.outcome).to eq(:confirmed_post)
    expect(partial.application_state).to eq(:pending)
    expect(partial.continuation_state).to eq(:pending)
    expect(partial.resolved?).to be(false)
    expect(@effects).to be_empty
    receipt = reconcile
    expect_resumed(receipt)
    expect(result_of(receipt.execution_task).fetch(:output)).to eq("approved answer")
    expect(result_of(@original).fetch(:output)).to eq("approved answer")
    expect(@writes).to eq(1)
    expect(@effects).to eq(["1:0"])
    expect(@calls.size).to eq(2)
  end

  it "keeps an accepted read after completion callback registration fails until physical completion" do
    setup_wait
    start_unknown
    waiting = gate
    admitted = Queue.new
    submissions = 0
    allow(@environment).to receive(:submit).and_wrap_original do |original, **options, &work|
      submissions += 1
      original.call(**options) do
        waiting.fetch(:entered) << true
        waiting.fetch(:release).pop
        work.call
      end.tap do |task|
        allow(task).to receive(:on_complete).and_raise(IOError, "read callback registration failed")
        admitted << task
      end
    end
    first = @agent.reconcile_approval_async(recovery: @recovery)
    worker = take(admitted)
    take(waiting.fetch(:entered))
    expect_pending(result_of(first), outcome: :unavailable, physical: false)
    second = @agent.reconcile_approval_async(recovery: @recovery)
    on_owner { true }
    expect(submissions).to eq(1)
    allow(@environment).to receive(:submit).and_call_original
    waiting.fetch(:release) << true
    eventually { worker.physical_complete? }

    receipt = result_of(second)
    expect_resumed(receipt)
    expect(result_of(receipt.execution_task).fetch(:output)).to eq("approved answer")
    expect(@effects).to eq(["1:0"])
    expect(@calls.size).to eq(2)
  end

  it "rejects synchronous recovery from the original EventLoop before persistence I/O" do
    setup_wait
    start_unknown
    expect(@store.coordinator).not_to receive(:atomic)

    failure = on_owner do
      @agent.reconcile_approval(recovery: @recovery)
    rescue => error
      error
    end

    expect(failure).to be_a(Phronomy::EventLoopReentrancyError)
    expect(@effects).to be_empty
    expect(@calls.size).to eq(1)
  end

  it "retains a read whose submission lost its handle without overlapping a replacement read" do
    setup_wait
    start_unknown
    waiting = gate
    accepted = Queue.new
    submissions = 0
    allow(@environment).to receive(:submit).and_wrap_original do |original, **options, &work|
      submissions += 1
      accepted << original.call(**options) do
        waiting.fetch(:entered) << true
        waiting.fetch(:release).pop
        work.call
      end
      raise IOError, "accepted approval read lost its handle"
    end
    observer = @agent.reconcile_approval_async(recovery: @recovery)
    hidden = take(accepted)
    take(waiting.fetch(:entered))

    expect_pending(result_of(observer), outcome: :unavailable, physical: false)
    expect_pending(reconcile, outcome: :unavailable, physical: false)
    waiting.fetch(:release) << true
    eventually { hidden.physical_complete? }
    expect_pending(reconcile, outcome: :unavailable, physical: false)
    expect(submissions).to eq(1)
    expect(@runtime.shutdown(timeout: 0.02, cancel_grace: 0.02).cleanup_complete?).to be(false)
  end

  it "continues only missing child registrations after a partial approval continuation" do
    waiting = gate
    setup_wait(children: 2, tool_gate: waiting)
    start_unknown
    registrations = []
    fail_once = true
    allow(@environment).to receive(:register_session).and_wrap_original do |original, session, **options|
      registrations << session.id
      if registrations.size == 3 && fail_once
        fail_once = false
        raise IOError, "second Tool registration interrupted before admission"
      end
      original.call(session, **options)
    end

    partial = reconcile

    expect(partial.outcome).to eq(:confirmed_post)
    expect(partial.application_state).to eq(:applied)
    expect(partial.continuation_state).to eq(:pending)
    expect(partial.resolved?).to be(false)
    expect(partial.physical_complete?).to be(true)
    retained_ids = registrations.first(3)
    expect(@calls.size).to eq(1)
    expect(@effects).to be_empty
    receipt = reconcile
    expect_resumed(receipt)
    observed = 2.times.map { take(waiting.fetch(:entered)) }
    expect(observed).to match_array(["1:0", "1:1"])
    expect(live_snapshot).to include(admission: :executing)
    expect(retained_ids.map { |id| registrations.count(id) }).to eq([1, 1, 2])
    2.times { waiting.fetch(:release) << true }

    expect(result_of(receipt.execution_task).fetch(:output)).to eq("approved answer")
    expect(result_of(@original).fetch(:output)).to eq("approved answer")
    expect(@effects).to match_array(["1:0", "1:1"])
    expect(@calls.size).to eq(2)
  end

  it "does not register an accepted child twice when its registration response is lost" do
    waiting = gate
    setup_wait(children: 2, tool_gate: waiting)
    start_unknown
    registrations = []
    allow(@environment).to receive(:register_session).and_wrap_original do |original, session, **options|
      registrations << session.id
      result = original.call(session, **options)
      raise IOError, "accepted second Tool registration lost its response" if registrations.size == 3
      result
    end

    first = reconcile
    retained_ids = registrations.first(3)
    receipt = first.resolved? ? first : reconcile

    expect_resumed(receipt)
    observed = 2.times.map { take(waiting.fetch(:entered)) }
    expect(observed).to match_array(["1:0", "1:1"])
    expect(live_snapshot).to include(admission: :executing)
    expect(retained_ids.size).to eq(3)
    expect(retained_ids.map { |id| registrations.count(id) }).to eq([1, 1, 1])
    expect(registrations.uniq.size).to eq(registrations.size)
    2.times { waiting.fetch(:release) << true }
    expect(result_of(receipt.execution_task).fetch(:output)).to eq("approved answer")
    expect(@effects).to match_array(["1:0", "1:1"])
    expect(@calls.size).to eq(2)
  end

  it "does not publish resolution while exact registry removal is still provisional" do
    tool_wait = gate
    setup_wait(tool_gate: tool_wait)
    start_unknown
    removal = gate
    fail_once = true
    allow(@registry).to receive(:resolve_approval_operation).and_wrap_original do |original, operation|
      if fail_once
        fail_once = false
        removal.fetch(:entered) << true
        removal.fetch(:release).pop
        raise IOError, "exact approval removal interrupted before deletion"
      end
      original.call(operation)
    end
    first = @agent.reconcile_approval_async(recovery: @recovery)
    take(removal.fetch(:entered))
    second = @agent.reconcile_approval_async(recovery: @recovery)

    expect { second.wait_result(timeout: 0.02) }.to raise_error(Phronomy::TimeoutError)

    second.cancel!
    removal.fetch(:release) << true
    partial = result_of(first)
    expect(partial.outcome).to eq(:confirmed_post)
    expect(partial.application_state).to eq(:applied)
    expect(partial.continuation_state).to eq(:pending)
    expect(partial.resolved?).to be(false)
    expect(@agent.pending_approval_recovery(execution_id: @request.execution_id)).to equal(@recovery)
    take(tool_wait.fetch(:entered))
    receipt = reconcile
    expect_resumed(receipt)
    tool_wait.fetch(:release) << true
    expect(result_of(receipt.execution_task).fetch(:output)).to eq("approved answer")
    expect(@effects).to eq(["1:0"])
    expect(@calls.size).to eq(2)
  end

  it "keeps the committed registry resolution when its response is lost after exact deletion" do
    setup_wait
    start_unknown
    removals = 0
    allow(@registry).to receive(:resolve_approval_operation).and_wrap_original do |original, operation|
      removals += 1
      original.call(operation)
      raise IOError, "approval removal reply lost after exact deletion"
    end

    receipt = reconcile

    expect_resumed(receipt)
    expect(result_of(receipt.execution_task).fetch(:output)).to eq("approved answer")
    expect_resumed(reconcile)
    expect(removals).to eq(1)
    expect(@effects).to eq(["1:0"])
    expect(@calls.size).to eq(2)
  end

  it "abandons a positively unadmitted child after the accepted parent finishes cancellation" do
    setup_wait(children: 2)
    start_unknown
    registrations = []
    allow(@environment).to receive(:register_session).and_wrap_original do |original, session, **options|
      registrations << session.id
      raise IOError, "second Tool definitely not admitted" if registrations.size == 3
      original.call(session, **options)
    end
    partial = reconcile
    expect(partial.outcome).to eq(:confirmed_post)
    expect(partial.application_state).to eq(:applied)
    expect(partial.continuation_state).to eq(:pending)
    @token.cancel!

    expect { result_of(@original) }.to raise_error(Phronomy::CancellationError)

    receipt = reconcile
    expect_resumed(receipt)
    expect { result_of(receipt.execution_task) }.to raise_error(Phronomy::CancellationError)
    expect(registrations.size).to eq(3)
    expect(@store.executions.load(@request.execution_id).status).to eq(:cancelled)
    again = reconcile
    expect_resumed(again)
    expect(registrations.size).to eq(3)
    expect(@effects).to be_empty
    expect(@calls.size).to eq(1)
  end

  it "never reinterprets unknown child admission as permission to register that child again" do
    setup_wait(children: 2)
    start_unknown
    registrations = []
    allow(@environment).to receive(:register_session).and_wrap_original do |original, session, **options|
      registrations << session.id
      raise IOError, "second Tool admission response unavailable" if registrations.size == 3
      original.call(session, **options)
    end
    queries = 0
    allow(@environment).to receive(:session_admitted?) do |_session_id|
      queries += 1
      raise IOError, "same-owner admission query unavailable"
    end
    first = reconcile
    expect(first.outcome).to eq(:confirmed_post)
    expect(first.application_state).to eq(:applied)
    expect(first.continuation_state).to eq(:pending)
    expect(first.resolved?).to be(false)
    allow(@environment).to receive(:session_admitted?).and_return(false)

    repeated = reconcile

    expect(repeated.continuation_state).to eq(:pending)
    expect(repeated.resolved?).to be(false)
    expect(registrations.size).to eq(3)
    expect(queries).to eq(1)
    expect(@agent.pending_approval_recovery(execution_id: @request.execution_id)).to equal(@recovery)
    expect(live_snapshot).to include(admission: :recovery_required)
    expect(@effects).to be_empty
    expect(@calls.size).to eq(1)
    parent_finished = Queue.new
    operation = @recovery.send(:operation)
    allow(operation).to receive(:parent_finished).and_wrap_original do |original, *arguments, &continuation|
      result = original.call(*arguments, &continuation)
      parent_finished << result
      result
    end
    @token.cancel!
    expect(take(parent_finished)).to be(false)
    after_parent_terminal = reconcile
    expect(after_parent_terminal.continuation_state).to eq(:pending)
    expect(after_parent_terminal.resolved?).to be(false)
    expect(@registry.agent_execution_admitted?(@agent.agent_id)).to be(true)
    expect(@agent.pending_approval_recovery(execution_id: @request.execution_id)).to equal(@recovery)
    expect(registrations.size).to eq(3)
    expect(@effects).to be_empty
    expect(@calls.size).to eq(1)
    expect(@runtime.shutdown(timeout: 0.02, cancel_grace: 0.02).cleanup_complete?).to be(false)
  end

  it "does not report shutdown complete while a durable approval decision remains unresolved" do
    setup_wait
    start_unknown(mode: :pre)

    stopped = @runtime.shutdown(timeout: 0.02, cancel_grace: 0.02)

    expect(stopped.cleanup_complete?).to be(false)
    expect(@agent.pending_approval_recovery(execution_id: @request.execution_id)).to equal(@recovery)
    expect(@effects).to be_empty
    expect(@calls.size).to eq(1)
  end
end
