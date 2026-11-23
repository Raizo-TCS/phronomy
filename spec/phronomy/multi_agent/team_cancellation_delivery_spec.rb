# frozen_string_literal: true

require "spec_helper"
require_relative "support/durable_coordination"

RSpec.describe "Team cancellation delivery through the owning host" do
  include_context "durable coordination runtime"

  def eventually(timeout: 4)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if yield
      raise "condition did not become true" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.001
    end
  end

  def start_turn(team, token, execution_id: nil)
    Thread.new do
      if execution_id
        team.resume(execution_id, config: {cancellation_token: token})
      else
        team.invoke("plan", config: {cancellation_token: token})
      end
    rescue => error
      error
    end
  end

  def turn_value(turn)
    expect(turn.join(5)).not_to be_nil
    turn.value
  end

  # The provider is real framework work. Only its HTTP response is held; no
  # Team wait, cancellation controller, or Agent result is replaced.
  def hold_worker_response
    entered, release = Queue.new, Queue.new
    llm = LLMStub.activate(responses: team_responses)
    allow(llm).to receive(:handle).and_wrap_original do |original, request|
      messages = JSON.parse(request.body).fetch("messages")
      if messages.any? { |message| message["role"] == "user" && message["content"] == "task-one" }
        entered << true
        raise "worker response gate timed out" unless release.pop(timeout: 10)
      end
      original.call(request)
    end
    [llm, entered, release]
  end

  def cancellation_fault
    fault = {enabled: true, mutex: Mutex.new, error: IOError.new("cancellation storage unavailable")}
    allow(store.backend).to receive(:replace_record).and_wrap_original do |original, context, resource, **options|
      if resource.id == "team.executions"
        execution = Phronomy::MultiAgent::Persistence::Codec.decode_team_execution(options.fetch(:entry).record)
        if execution.metadata["cancel_requested"] && fault.fetch(:mutex).synchronize { fault.fetch(:enabled) }
          raise fault.fetch(:error)
        end
      end
      original.call(context, resource, **options)
    end
    fault
  end

  def restore_cancellation_storage(fault)
    fault&.fetch(:mutex)&.synchronize { fault[:enabled] = false }
  end

  def expect_delivery_error(error, team, run, cause: nil)
    expect(error).to be_a(Phronomy::MultiAgent::TeamCancellationDeliveryError)
    expect(error.code).to eq("team.cancellation_delivery")
    expect(error.team_id).to eq(team.team_id)
    expect(error.team_execution_id).to eq(run.team_execution_id)
    expect(error.cause).to equal(cause) if cause
  end

  def child_released?(id)
    Phronomy::Agent::Base.get(id).nil?
  rescue Phronomy::AgentBusyError
    false
  end

  [:invoke, :stream].each do |entrypoint|
    it "accepts an already-cancelled token inline through #{entrypoint} before starting a child" do
      team = team_class.create(persistence: store.multi_agent)
      external = Phronomy::Concurrency::CancellationToken.new.cancel!
      llm = LLMStub.activate(responses: ["must not invoke the provider"])
      environment = team.instance_variable_get(:@environment)
      allow(environment).to receive(:submit).and_raise(Phronomy::BackpressureError, "queue full")

      expect { team.public_send(entrypoint, "plan", config: {cancellation_token: external}) }
        .to raise_error(Phronomy::CancellationError)

      run = team.executions.first
      expect(run.status).to eq("cancelled")
      expect(run.metadata.fetch("cancel_requested")).to be(true)
      expect(store.agent.observe_execution(agent_id: run.coordinator.fetch("agent_id"),
        execution_id: run.coordinator.fetch("execution_id")).absent?).to be(true)
      expect(llm.calls).to be_empty
      expect(environment).not_to have_received(:submit)
      expect(team.instance_variable_get(:@admissions)).to be_idle
    end
  end

  it "persists cancellation while both the ordinary pool and a child provider are blocked" do
    Phronomy.configure do |config|
      config.offload_pool_size = 1
      config.offload_queue_size = 8
    end
    team = team_class.create(persistence: store.multi_agent)
    external = Phronomy::Concurrency::CancellationToken.new
    llm, entered, release_provider = hold_worker_response
    turn = start_turn(team, external)
    expect(entered.pop(timeout: 5)).to be(true)
    run = team.executions.first
    child_id = run.workers.first.fetch("agent_id")
    child = Phronomy::Agent::Base.get(child_id)
    runtime = Phronomy::Runtime.instance
    environment = team.instance_variable_get(:@environment)
    # The held provider already occupies the only ordinary worker.
    expect(runtime.offload.active_count).to eq(1)
    queued = Array.new(8) { runtime.offload.submit(on_full: :raise) { :queued_work } }
    expect { environment.submit(on_full: :raise) { :must_not_run } }
      .to raise_error(Phronomy::BackpressureError)
    allow(environment).to receive(:submit).and_call_original

    external.cancel!

    eventually { team.executions.first.metadata["cancel_requested"] }
    expect(environment).not_to have_received(:submit)
    expect(Phronomy::Agent::Base.get(child_id)).to equal(child)
    release_provider << true
    expect(queued.map { |task| task.wait_result(timeout: 5) }).to eq(Array.new(8, :queued_work))
    expect(turn_value(turn)).to be_a(Phronomy::CancellationError)
    expect(team.executions.first.status).to eq("cancelled")
    eventually { child_released?(child_id) }
    expect(llm.calls.size).to eq(4)
  ensure
    release_provider&.push(true)
    turn&.join(5)
  end

  it "confirms a lost cancellation commit response by reading the committed Team record" do
    team = team_class.create(persistence: store.multi_agent)
    external = Phronomy::Concurrency::CancellationToken.new
    llm, entered, release = hold_worker_response
    turn = start_turn(team, external)
    expect(entered.pop(timeout: 5)).to be(true)
    lost = false
    store.after_commit = proc do |backend|
      next if lost
      if backend.multi_agent.runs(team.team_id).first.metadata["cancel_requested"]
        lost = true
        raise IOError, "cancellation commit response lost"
      end
    end

    external.cancel!
    eventually { team.executions.first.metadata["cancel_requested"] }
    release << true

    expect(turn_value(turn)).to be_a(Phronomy::CancellationError)
    expect(lost).to be(true)
    expect(team.executions.first.status).to eq("cancelled")
    expect(team.instance_variable_get(:@admissions)).to be_idle
    expect(llm.calls.size).to eq(4)
  ensure
    store.after_commit = nil
    release&.push(true)
    turn&.join(5)
  end

  [:resume, :cancel].each do |retry_operation|
    it "retains pending intent after observer failure and retries it through exact #{retry_operation}" do
      team = team_class.create(persistence: store.multi_agent)
      external = Phronomy::Concurrency::CancellationToken.new
      llm, entered, release = hold_worker_response
      turn = start_turn(team, external)
      expect(entered.pop(timeout: 5)).to be(true)
      run = team.executions.first
      child_id = run.workers.first.fetch("agent_id")
      child = Phronomy::Agent::Base.get(child_id)
      fault = cancellation_fault

      external.cancel!
      expect_delivery_error(turn_value(turn), team, run, cause: fault.fetch(:error))
      expect(team.executions.first.status).to eq("active")
      expect(team.executions.first.metadata["cancel_requested"]).not_to be(true)
      expect(team.instance_variable_get(:@admissions)).not_to be_idle
      expect(Phronomy::Agent::Base.get(child_id)).to equal(child)
      expect { team.invoke("another run") }
        .to raise_error(Phronomy::MultiAgent::TeamCancellationDeliveryError)
      expect { team.resume("another-execution") }
        .to raise_error(Phronomy::MultiAgent::TeamCancellationDeliveryError)
      expect(team.executions.size).to eq(1)

      restore_cancellation_storage(fault)
      if retry_operation == :cancel
        expect(team.cancel(run.team_execution_id).fetch(:team_execution_id)).to eq(run.team_execution_id)
        expect(team.executions.first.metadata.fetch("cancel_requested")).to be(true)
      end
      resumed = start_turn(team, Phronomy::Concurrency::CancellationToken.new,
        execution_id: run.team_execution_id)
      eventually { team.executions.first.metadata["cancel_requested"] }
      release << true
      expect(turn_value(resumed)).to be_a(Phronomy::CancellationError)
      expect(team.executions.first.status).to eq("cancelled")
      expect(team.instance_variable_get(:@admissions)).to be_idle
      eventually { child_released?(child_id) }
      expect(llm.calls.size).to eq(4)
    ensure
      restore_cancellation_storage(fault)
      release&.push(true)
      turn&.join(5)
      resumed&.join(5)
    end
  end

  it "does not turn result-query failure into unconfirmed cancellation after the intent committed" do
    team = team_class.create(persistence: store.multi_agent)
    fault = cancellation_fault
    llm = LLMStub.activate(responses: ["must not invoke the provider"])
    expect { team.invoke("plan", config: {cancellation_token: Phronomy::Concurrency::CancellationToken.new.cancel!}) }
      .to raise_error(Phronomy::MultiAgent::TeamCancellationDeliveryError)
    run = team.executions.first
    restore_cancellation_storage(fault)
    allow(store.multi_agent).to receive(:result).with(run.team_execution_id)
      .and_raise(IOError, "result query unavailable")

    expect { team.cancel(run.team_execution_id) }.to raise_error(IOError, "result query unavailable")

    expect(team.executions.first.metadata.fetch("cancel_requested")).to be(true)
    expect(team.instance_variable_get(:@admissions)).to be_idle
    allow(store.multi_agent).to receive(:result).and_call_original
    expect { team.resume(run.team_execution_id) }.to raise_error(Phronomy::CancellationError)
    expect(team.executions.first.status).to eq("cancelled")
    expect(llm.calls).to be_empty
  ensure
    restore_cancellation_storage(fault)
  end

  it "retains a cancellation accepted immediately before an ordinary host failure" do
    team = team_class.create(persistence: store.multi_agent)
    external = Phronomy::Concurrency::CancellationToken.new
    failure = IOError.new("application scheduler unavailable")
    team_class.schedule do |_available|
      external.cancel!
      raise failure
    end
    llm = LLMStub.activate(responses: team_responses)
    error = begin
      team.invoke("plan", config: {cancellation_token: external})
    rescue => caught
      caught
    end
    run = team.executions.first

    expect_delivery_error(error, team, run, cause: failure)
    expect(run.status).to eq("active")
    expect(run.metadata["cancel_requested"]).not_to be(true)
    expect(team.instance_variable_get(:@admissions)).not_to be_idle
    team_class.schedule { |available| available.first }
    expect { team.resume(run.team_execution_id) }.to raise_error(Phronomy::CancellationError)
    expect(team.executions.first.metadata.fetch("cancel_requested")).to be(true)
    expect(team.executions.first.status).to eq("cancelled")
    expect(team.instance_variable_get(:@admissions)).to be_idle
    expect(llm.calls.size).to eq(3)
  end

  it "honors a concurrent direct confirmation when the host's older attempt and readback later fail" do
    team = team_class.create(persistence: store.multi_agent)
    external = Phronomy::Concurrency::CancellationToken.new
    llm, entered, release_provider = hold_worker_response
    turn = start_turn(team, external)
    expect(entered.pop(timeout: 5)).to be(true)
    run = team.executions.first
    attempt_entered, release_attempt = Queue.new, Queue.new
    claimed = false
    fail_readback = false
    readback_failed = false
    # Pause at the Store transaction entry, before it holds any storage lock,
    # so the independent direct cancellation can commit on the real backend.
    allow(store.multi_agent).to receive(:transaction).and_wrap_original do |original, &operation|
      if Thread.current.equal?(turn) && !claimed
        claimed = true
        attempt_entered << true
        raise "cancellation attempt gate timed out" unless release_attempt.pop(timeout: 10)
        fail_readback = true
        raise IOError, "older cancellation attempt unavailable"
      end
      original.call(&operation)
    end
    allow(store.multi_agent.team_executions).to receive(:load).and_wrap_original do |original, id|
      if Thread.current.equal?(turn) && fail_readback
        fail_readback = false
        readback_failed = true
        raise IOError, "older cancellation readback unavailable"
      end
      original.call(id)
    end

    external.cancel!
    expect(attempt_entered.pop(timeout: 5)).to be(true)
    expect(team.cancel(run.team_execution_id).fetch(:team_execution_id)).to eq(run.team_execution_id)
    expect(team.executions.first.metadata.fetch("cancel_requested")).to be(true)
    release_attempt << true
    release_provider << true

    expect(turn_value(turn)).to be_a(Phronomy::CancellationError)
    expect(readback_failed).to be(true)
    expect(team.executions.first.status).to eq("cancelled")
    expect(team.instance_variable_get(:@admissions)).to be_idle
    expect(llm.calls.size).to eq(4)
  ensure
    release_attempt&.push(true)
    release_provider&.push(true)
    turn&.join(5)
  end

  it "preserves the completed business result when cancellation races the terminal commit response" do
    team = team_class.create(persistence: store.multi_agent)
    external = Phronomy::Concurrency::CancellationToken.new
    llm = LLMStub.activate(responses: team_responses)
    committed = nil
    store.after_commit = proc do |backend|
      next if committed
      current = backend.multi_agent.runs(team.team_id).first
      if current&.status == "completed"
        committed = current.to_h
        external.cancel!
      end
    end

    result = team.invoke("plan", config: {cancellation_token: external})

    expect(result.first.fetch("result")).to eq("worker-result")
    run = team.executions.first
    expect(run.to_h).to eq(committed)
    expect(run.status).to eq("completed")
    expect(team.cancel(run.team_execution_id).fetch(:status)).to eq("completed")
    expect(team.executions.first.to_h).to eq(committed)
    expect(team.instance_variable_get(:@admissions)).to be_idle
    expect(llm.calls.size).to eq(4)
  ensure
    store.after_commit = nil
  end

  it "rejects a callback already taken from an earlier registration after the same run resumes" do
    team = team_class.create(persistence: store.multi_agent)
    old_token = Phronomy::Concurrency::CancellationToken.new
    new_token = Phronomy::Concurrency::CancellationToken.new
    scheduler_entered, release_scheduler = Queue.new, Queue.new
    callback_taken, release_callback = Queue.new, Queue.new
    first_schedule = true
    team_class.schedule do |available|
      if first_schedule
        first_schedule = false
        scheduler_entered << true
        raise "scheduler gate timed out" unless release_scheduler.pop(timeout: 10)
        raise IOError, "application scheduler unavailable"
      end
      available.first
    end
    allow(old_token).to receive(:deliver_cancel_callback).and_wrap_original do |original, callback|
      callback_taken << true
      raise "callback gate timed out" unless release_callback.pop(timeout: 10)
      original.call(callback)
    end
    llm, entered, release_provider = hold_worker_response
    first = start_turn(team, old_token)
    expect(scheduler_entered.pop(timeout: 5)).to be(true)
    cancellation = Thread.new { old_token.cancel! }
    expect(callback_taken.pop(timeout: 5)).to be(true)
    release_scheduler << true
    expect(turn_value(first)).to be_a(IOError)
    run = team.executions.first
    resumed = start_turn(team, new_token, execution_id: run.team_execution_id)
    expect(entered.pop(timeout: 5)).to be(true)

    release_callback << true
    expect(cancellation.join(5)).not_to be_nil
    expect(new_token).not_to be_cancelled
    expect(team.executions.first.metadata["cancel_requested"]).not_to be(true)
    release_provider << true

    expect(turn_value(resumed).first.fetch("result")).to eq("worker-result")
    expect(team.executions.first.status).to eq("completed")
    expect(team.instance_variable_get(:@admissions)).to be_idle
    expect(llm.calls.size).to eq(4)
  ensure
    release_scheduler&.push(true)
    release_callback&.push(true)
    release_provider&.push(true)
    cancellation&.join(5)
    first&.join(5)
    resumed&.join(5)
  end

  it "keeps pending responsibility through incomplete Runtime shutdown and a later direct confirmation" do
    # The shared fixture normally looks up a live EventLoop to check its thread.
    # This case must keep that assertion without acquiring a failed Runtime.
    allow(store).to receive(:check_io_thread!) do |operation|
      raise "Persistence #{operation} must not run on EventLoop" if Phronomy::Runtime.in_event_loop_context?
      store.before_io&.call(operation)
    end
    team = team_class.create(persistence: store.multi_agent)
    runtime = Phronomy::Runtime.instance
    fault = cancellation_fault
    llm = LLMStub.activate(responses: ["must not invoke the provider"])
    expect { team.invoke("plan", config: {cancellation_token: Phronomy::Concurrency::CancellationToken.new.cancel!}) }
      .to raise_error(Phronomy::MultiAgent::TeamCancellationDeliveryError)
    run = team.executions.first
    admissions = team.instance_variable_get(:@admissions)

    shutdown = runtime.shutdown(timeout: 0, cancel_grace: 0)

    expect(shutdown).not_to be_cleanup_complete
    expect(admissions).not_to be_idle
    expect(team_class.get(team.team_id)).to equal(team)
    restore_cancellation_storage(fault)
    expect(team.cancel(run.team_execution_id).fetch(:status)).to eq("active")
    expect(team.executions.first.metadata.fetch("cancel_requested")).to be(true)
    expect(admissions).to be_idle
    expect(runtime.shutdown(timeout: 0)).to equal(shutdown)
    expect { Phronomy::Runtime.reset_default!(timeout: 0) }.to raise_error(Phronomy::RuntimeShutdownError)
    expect { team.resume(run.team_execution_id) }.to raise_error(Phronomy::RuntimeShutdownError)
    expect(llm.calls).to be_empty
  ensure
    restore_cancellation_storage(fault)
  end

  it "fences an old Team owner before storage after the default Runtime is replaced" do
    team = team_class.create(persistence: store.multi_agent)
    old_runtime = Phronomy::Runtime.instance
    fault = cancellation_fault
    LLMStub.activate(responses: ["must not invoke the provider"])
    expect { team.invoke("plan", config: {cancellation_token: Phronomy::Concurrency::CancellationToken.new.cancel!}) }
      .to raise_error(Phronomy::MultiAgent::TeamCancellationDeliveryError)
    run = team.executions.first
    restore_cancellation_storage(fault)
    replacement = Phronomy::Runtime.new
    Phronomy::Runtime.replace_default_for_test(replacement)
    expect(store.multi_agent).not_to receive(:transaction)

    expect { team.cancel(run.team_execution_id) }.to raise_error(Phronomy::RuntimeShutdownError, /previous Runtime/)
    expect { team.resume(run.team_execution_id) }.to raise_error(Phronomy::RuntimeShutdownError, /previous Runtime/)
    expect(team.instance_variable_get(:@admissions)).not_to be_idle
  ensure
    replacement&.shutdown(timeout: 0)
    Phronomy::Runtime.restore_default_for_test(old_runtime) if old_runtime
    restore_cancellation_storage(fault)
  end
end
