# frozen_string_literal: true

require "spec_helper"
require_relative "../multi_agent/support/durable_coordination"

RSpec.describe "Recovery Persistence I/O boundary (ADR-014/024; F1/F4)" do
  include_context "durable coordination runtime"

  # Real Provider and recovery sessions produce the durable snapshots. The
  # fixture rejects EventLoop Persistence calls in all subsequent paths.
  def pending_provider
    agent = worker.create(agent_id: "io-recovery", persistence: store)
    captured = nil
    store.after_commit = proc do |backend|
      execution = backend.list_executions(agent.agent_id).first
      captured ||= backend.snapshot if execution&.phase == :calling_llm
    end
    LLMStub.activate(responses: ["original output"])
    agent.invoke("input")
    expect(captured).not_to be_nil
    restored = reboot(captured)
    events = Queue.new
    loaded = worker.load(agent.agent_id, persistence: restored,
      on_event: ->(event) { events << event.payload if event.type == :recovery_resolution_required })
    [restored, loaded, Timeout.timeout(3) { events.pop }]
  end

  def resolve_output(agent, event)
    outcome = Phronomy::Agent::ProviderCallOutcome.new(role: :assistant, content: "saved output", tool_calls: [])
    agent.resolve_async(event.fetch(:execution_id), expected_execution_revision: event.fetch(:execution_revision),
      subject: event.fetch(:subject), outcome: :succeeded, result: outcome.to_h)
  end

  def capture_resolution(backend, id, &after_capture)
    snapshots = Queue.new
    backend.after_commit = proc do |current|
      execution = current.executions.load(id)
      if execution.phase == :recovery_provider_completed
        snapshots << current.snapshot
        after_capture&.call
      end
    end
    snapshots
  end

  # No sleep-based timing assumptions: the worker acknowledges its blocked read.
  def block_read(backend, operation)
    entered, release = Queue.new, Queue.new
    once = false
    lock = Mutex.new
    backend.before_io = proc do |actual|
      should_block = lock.synchronize do
        next false if once || actual != operation
        once = true
      end
      if should_block
        entered << Thread.current.name
        release.pop
      end
    end
    [entered, release]
  end

  it "materializes resolved output off EventLoop and applies live invocation state on EventLoop" do
    restored, loaded, event = pending_provider
    threads = Queue.new
    restored.before_io = ->(operation) { threads << Thread.current.name if operation == :fetch }
    allow(Phronomy::Agent::RecoverySupport).to receive(:build_chat_for_recovery).and_wrap_original do |method, *args, **kwargs|
      expect(Phronomy::Runtime.instance.event_loop.current?).to be(true)
      method.call(*args, **kwargs)
    end
    llm = LLMStub.activate(responses: ["must not replay"])
    expect(resolve_output(loaded, event).wait_result(timeout: 3)[:output]).to eq("saved output")
    expect(threads).not_to be_empty
    observed = []
    observed << threads.pop until threads.empty?
    expect(observed).to all(match(/offload-pool/))
    expect(llm.calls).to be_empty
  end

  it "restores a resolved Provider snapshot without EventLoop reads or Provider replay" do
    restored, loaded, event = pending_provider
    snapshots = capture_resolution(restored, event.fetch(:execution_id))
    resolve_output(loaded, event).wait_result(timeout: 3)
    recovered = reboot(Timeout.timeout(3) { snapshots.pop })
    terminal = Queue.new
    recovered.after_commit = proc do |backend|
      execution = backend.executions.load(event.fetch(:execution_id))
      terminal << execution if execution.terminal?
    end
    llm = LLMStub.activate(responses: ["must not replay"])
    worker.load(loaded.agent_id, persistence: recovered)
    expect(Timeout.timeout(3) { terminal.pop }.status).to eq(:completed)
    expect(recovered.execution_result(event.fetch(:execution_id))[:result]).to eq("saved output")
    expect(llm.calls).to be_empty
  end

  [:materialization, :f1_readback].each do |boundary|
    it "lets an unrelated Agent finish while #{boundary} is blocked" do
      restored, loaded, event = pending_provider
      independent = worker.create(agent_id: "independent", persistence: Phronomy::Persistence::InMemory.new)
      if boundary == :f1_readback
        # Throw after commit; the next execution load is the authoritative F1 read.
        restored.after_commit = proc do |_backend|
          restored.after_commit = nil
          raise IOError, "commit response lost"
        end
      end
      entered, release = block_read(restored, (boundary == :materialization) ? :fetch : :load)
      llm = LLMStub.activate(responses: ["independent output"])
      resolution = resolve_output(loaded, event)
      expect(Timeout.timeout(3) { entered.pop }).to match(/offload-pool/)
      expect(resolution).not_to be_done
      expect(independent.invoke_async("unrelated").wait_result(timeout: 3)[:output]).to eq("independent output")
      expect(resolution).not_to be_done
      release << true
      expect(resolution.wait_result(timeout: 3)[:output]).to eq("saved output")
      expect(llm.calls.size).to eq(1)
    ensure
      release << true if release
    end
  end

  it "retains a confirmed resolution when materialization fails and recovers it after F4" do
    restored, loaded, event = pending_provider
    restored.before_io = proc { |operation| raise IOError, "content read unavailable" if operation == :fetch }
    llm = LLMStub.activate(responses: ["must not replay"])
    expect { resolve_output(loaded, event).wait_result(timeout: 3) }.to raise_error(IOError, /content read unavailable/)
    saved = restored.executions.load(event.fetch(:execution_id))
    expect(saved.phase).to eq(:recovery_provider_completed)
    expect(saved).not_to be_terminal
    expect(saved.execution_revision).to eq(event.fetch(:execution_revision) + 1)
    expect { resolve_output(loaded, event).wait_result(timeout: 3) }.to raise_error(Phronomy::Persistence::ConflictError)
    recovered = reboot(restored.snapshot)
    terminal = Queue.new
    recovered.after_commit = proc do |backend|
      execution = backend.executions.load(saved.execution_id)
      terminal << execution if execution.terminal?
    end
    worker.load(loaded.agent_id, persistence: recovered)
    expect(Timeout.timeout(3) { terminal.pop }.status).to eq(:completed)
    expect(llm.calls).to be_empty
  end

  [IOError, Phronomy::Persistence::NotFoundError].each do |failure|
    it "does not treat #{failure} during F1 readback as permission to redispatch" do
      restored, loaded, event = pending_provider
      restored.after_commit = proc do |_backend|
        restored.after_commit = nil
        restored.before_io = proc { |operation| raise failure, "readback unavailable" if operation == :load }
        raise IOError, "commit response lost"
      end
      llm = LLMStub.activate(responses: ["must not replay"])
      expect { resolve_output(loaded, event).wait_result(timeout: 3) }.to raise_error(failure, /readback unavailable/)
      restored.before_io = nil
      saved = restored.executions.load(event.fetch(:execution_id))
      expect(saved.phase).to eq(:recovery_provider_completed)
      expect(saved).not_to be_terminal
      expect(llm.calls).to be_empty
    end
  end

  it "preserves the unresolved execution when a resolution write fails before commit" do
    restored, loaded, event = pending_provider
    restored.before_io = proc { |operation| raise IOError, "write unavailable" if operation == :transaction }
    expect { resolve_output(loaded, event).wait_result(timeout: 3) }.to raise_error(IOError, /write unavailable/)
    expect(restored.executions.load(event.fetch(:execution_id)).execution_revision).to eq(event.fetch(:execution_revision))
    restored.before_io = nil
    expect(resolve_output(loaded, event).wait_result(timeout: 3)[:output]).to eq("saved output")
  end

  it "rejects an F1 readback that matches neither the original nor intended execution" do
    restored, loaded, event = pending_provider
    restored.after_commit = proc do |backend|
      backend.after_commit = nil
      backend.transaction do |tx|
        current = tx.executions.load(event.fetch(:execution_id))
        tx.executions.save(current.execution_id, expected_revision: current.execution_revision,
          execution: current.with(metadata: current.metadata.merge("competing_write" => true)))
      end
      raise IOError, "commit response lost"
    end
    llm = LLMStub.activate(responses: ["must not replay"])
    expect { resolve_output(loaded, event).wait_result(timeout: 3) }
      .to raise_error(Phronomy::Persistence::ConflictError, /conflicts with both/)
    expect(restored.executions.load(event.fetch(:execution_id)).metadata["competing_write"]).to be(true)
    expect(llm.calls).to be_empty
  end

  it "does not apply a late resolution to a replaced live execution" do
    restored, loaded, event = pending_provider
    entered, release = block_read(restored, :fetch)
    resolution = resolve_output(loaded, event)
    Timeout.timeout(3) { entered.pop }
    event_loop = Phronomy::Runtime.instance.event_loop
    applied = Phronomy::Task.deferred(name: "replace-recovery-state")
    # Model a newer lifecycle update while the old worker is materializing.
    handler = Object.new
    handler.define_singleton_method(:deliver_on_event_loop) do |_command|
      state = event_loop.agent_execution_state(event.fetch(:execution_id))
      event_loop.replace_agent_execution(state.execution_id,
        execution: state.execution.with(metadata: state.execution.metadata.merge("newer_live_state" => true)))
      applied.complete(true)
    end
    command = Struct.new(:coordinator).new(handler)
    event_loop.post(Phronomy::Event.new(type: :agent_control,
      target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID, payload: {command: command}))
    applied.wait_result(timeout: 3)
    release << true
    expect { resolution.wait_result(timeout: 3) }
      .to raise_error(Phronomy::Persistence::ConflictError, /changed before resolution apply/)
    expect(restored.executions.load(event.fetch(:execution_id)).phase).to eq(:recovery_provider_completed)
  ensure
    release << true if release
  end

  it "fails the observer when EventLoop stops before a prepared result can be applied" do
    restored, loaded, event = pending_provider
    entered, release = block_read(restored, :fetch)
    resolution = resolve_output(loaded, event)
    Timeout.timeout(3) { entered.pop }
    event_loop = Phronomy::Runtime.instance.event_loop
    event_loop.stop_and_join(deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.2)
    release << true
    expect { resolution.wait_result(timeout: 3) }
      .to raise_error(Phronomy::RuntimeShutdownError, /rejected Recovery resolution apply/)
    expect(restored.executions.load(event.fetch(:execution_id)).phase).to eq(:recovery_provider_completed)
  ensure
    release << true if release
  end

  [true, false].each do |approved|
    it "restores approval waiting off EventLoop and resumes with approved=#{approved}" do
      calls = 0
      capability = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "protected_operation"
        description "Requires approval"
        requires_approval true
        define_method(:execute) {
          calls += 1
          "tool output"
        }
      end
      worker.tools(capability => nil)
      approvals = Queue.new
      listener = ->(event) { approvals << event.payload.fetch(:request) if event.type == :approval_required }
      original = worker.create(agent_id: "approval-recovery", persistence: store, on_event: listener)
      LLMStub.activate(responses: [LLMStub.tool_call_response("protected_operation", {}), "done"])
      original.invoke_async("input")
      request = Timeout.timeout(3) { approvals.pop }
      recovered = reboot(store.snapshot)
      llm = LLMStub.activate(responses: ["approved output"])
      loaded = worker.load(original.agent_id, persistence: recovered, on_event: listener)
      restored_request = Timeout.timeout(3) { approvals.pop }
      expect(restored_request.id).to eq(request.id)
      expect(calls).to eq(0)
      result = loaded.approve_async(request.execution_id, approval_request_id: request.id, approved: approved).wait_result(timeout: 3)
      if approved
        expect(result[:output]).to eq("approved output")
        expect(calls).to eq(1)
      else
        expect(result[:rejected]).to be(true)
        expect(calls).to eq(0)
        expect(llm.calls).to be_empty
      end
    end
  end
end
