# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe "Agent readback and captured-save submission custody" do
  CustodyGate = Struct.new(:entered, :release)

  def eventually
    Timeout.timeout(4) do
      loop do
        value = yield
        return value if value
        sleep 0.002
      end
    end
  end

  def take(queue)
    Timeout.timeout(4) { queue.pop }
  end

  def result_of(task)
    task.wait_result(timeout: 4)
  end

  def gate
    CustodyGate.new(entered: Queue.new, release: Queue.new).tap { |value| (@gates ||= []) << value }
  end

  # Storage faults produce a real retained Agent operation. Recovery requests
  # below use public APIs and the actual bounded Runtime worker pool.
  def setup_recovery(kind)
    @kind = kind
    @counts = counts = Hash.new(0)
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |_request, cancellation_token:|
        cancellation_token&.raise_if_cancelled!
        counts[:provider] += 1
        raise "Provider replayed during terminal recovery" unless counts[:provider] == 1
        Phronomy::LLMAdapter::Response.new(content: "retained answer", finish_reason: :stop)
      end
    end.new
    Phronomy.configure do |configuration|
      configuration.offload_pool_size = 1
      configuration.offload_queue_size = 1
      configuration.llm_adapter = adapter
    end
    @runtime = Phronomy::Runtime.instance
    @registry = Phronomy::Agent::ExecutionRegistry.for(@runtime.event_loop)
    @store = Phronomy::PersistenceComposition.in_memory.agent
    agent_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "recovery-submission-custody", version: 1
    end
    @events = []
    @agent = agent_class.create(agent_id: "recovery-custody-#{RSpec.current_example.metadata.fetch(:line_number)}",
      persistence: @store, on_event: ->(event) { @events << event })
    @environment = @agent.__execution_environment
    fault = {armed: true, terminal: false, read_failure: false}
    allow_any_instance_of(Phronomy::Agent::ExecutionOutcomeCommitter)
      .to receive(:commit_outcome).and_wrap_original do |original, command, **options|
        counts[:committer] += 1
        fault[:terminal] = true
        original.call(command, **options)
      end
    allow(@store.coordinator).to receive(:atomic).and_wrap_original do |original, &transaction|
      if fault[:armed] && fault[:terminal]
        fault[:armed] = false
        if kind == :retry
          original.call do |scope|
            transaction.call(scope)
            fault[:read_failure] = true
            raise IOError, "terminal transaction rolled back after complete capture"
          end
        else
          original.call(&transaction)
          fault[:read_failure] = true
          raise IOError, "terminal transaction reply lost after commit"
        end
      else
        original.call(&transaction)
      end
    end
    allow_any_instance_of(Phronomy::Agent::Persistence::ExecutionRepository)
      .to receive(:load).and_wrap_original do |original, execution_id|
        if fault[:read_failure]
          fault[:read_failure] = false
          raise IOError, "initial terminal readback unavailable"
        end
        original.call(execution_id)
      end
    @original = @agent.invoke_async("perform the original work once")
    expect { result_of(@original) }.to raise_error(Phronomy::Agent::TerminalRecoveryError) do |error|
      @original_error, @recovery, @execution_id = error, error.recovery, error.execution_id
    end
    eventually { @original.physical_complete? && @runtime.offload.active_count.zero? && @runtime.offload.queue_depth.zero? }
    expect(@counts).to eq(provider: 1, committer: 1)
    expect(@store.executions.load(@execution_id).status).to eq((kind == :retry) ? :active : :completed)
  end

  def request(kind = @kind)
    method = {reconcile: :reconcile_terminal_async, retry: :retry_terminal_async,
              submission: :retry_terminal_submission_async}.fetch(kind)
    @agent.public_send(method, recovery: @recovery)
  end

  def occupy_worker
    waiting = gate
    task = @runtime.offload.submit(on_full: :raise) do
      waiting.entered << true
      waiting.release.pop
    end
    take(waiting.entered)
    [waiting, task]
  end

  def expect_retained(value)
    expect(value.outcome).to eq(:unavailable)
    expect(value.application_state).to eq(:pending)
    expect(value.ownership_state).to eq(:retained)
    # Recovery-attempt admission does not replace the original terminal fact.
    expect(value.submission_state).to eq(:admitted)
    expect(@agent.pending_terminal_recovery(execution_id: @execution_id)).to equal(@recovery)
    expect(@registry.agent_execution_admitted?(@agent.agent_id)).to be(true)
    expect(@agent.agent_root.lifecycle_status).to eq(:active)
    expect(@counts).to eq(provider: 1, committer: 1)
  end

  def expect_released(value)
    expect(value.outcome).to eq(:confirmed_post)
    expect(value.application_state).to eq(:applied)
    expect(value.ownership_state).to eq(:released)
    expect(value.submission_state).to eq(:admitted)
    expect(value.execution.result).to eq("retained answer")
    expect(@agent.pending_terminal_recovery(execution_id: @execution_id)).to be_nil
    expect(@registry.agent_execution_admitted?(@agent.agent_id)).to be(false)
    expect(@counts).to eq(provider: 1, committer: 1)
    expect(@events.none? { |event| %i[done error cancelled].include?(event.type) }).to be(true)
    expect { result_of(@original) }.to raise_error { |error| expect(error).to equal(@original_error) }
  end

  def expect_lane_retained
    %i[reconcile retry submission].each { |kind| expect_retained(result_of(request(kind))) }
    expect { @agent.invoke("must not replace the retained owner") }.to raise_error(Phronomy::AgentBusyError)
    expect(@counts).to eq(provider: 1, committer: 1)
  end

  after do
    @gates&.each { |value| value.release << true }
    @runtime&.shutdown(timeout: 0.03, cancel_grace: 0.2)
  end

  %i[reconcile retry].each do |kind|
    %i[raise nil].each do |loss|
      it "retains #{kind} custody when an accepted queued worker loses its handle through #{loss}" do
        setup_recovery(kind)
        waiting, occupied = occupy_worker
        accepted = Queue.new
        submissions = 0
        allow(@environment).to receive(:submit).and_wrap_original do |original, **options, &work|
          submissions += 1
          accepted << original.call(**options, &work)
          raise Phronomy::BackpressureError, "wrapper lost the accepted recovery handle" if loss == :raise
          nil
        end

        expect_retained(result_of(request))
        hidden = take(accepted)
        expect(hidden.physical_complete?).to be(false)
        expect_lane_retained
        expect(submissions).to eq(1)
        expect(@runtime.offload.queue_depth).to eq(1)
        waiting.release << true
        result_of(occupied)
        result_of(hidden)
        expect(hidden.physical_complete?).to be(true)

        expect_lane_retained
        expect(submissions).to eq(1)
        expect(@store.executions.load(@execution_id).status).to eq(:completed)
      end
    end

    it "retains #{kind} custody when the worker starts before its submitter raises" do
      setup_recovery(kind)
      running = gate
      waits = [running]
      allow(@store.coordinator).to receive(:atomic).and_wrap_original do |original, &transaction|
        if (current = waits.shift)
          current.entered << true
          current.release.pop
        end
        original.call(&transaction)
      end
      accepted = Queue.new
      submissions = 0
      allow(@environment).to receive(:submit).and_wrap_original do |original, **options, &work|
        submissions += 1
        accepted << original.call(**options, &work)
        take(running.entered)
        raise IOError, "running recovery handle lost before return"
      end

      expect_retained(result_of(request))
      hidden = take(accepted)
      expect(hidden.physical_complete?).to be(false)
      expect_lane_retained
      expect(submissions).to eq(1)
      running.release << true
      result_of(hidden)

      expect_lane_retained
      expect(submissions).to eq(1)
      expect(@store.executions.load(@execution_id).status).to eq(:completed)
    end

    it "allows fresh explicit #{kind} after actual full-pool refusal" do
      setup_recovery(kind)
      waiting, occupied = occupy_worker
      queued = @runtime.offload.submit(on_full: :raise) { :filler }
      expect(@runtime.offload.queue_depth).to eq(1)

      twice = Array.new(2) { result_of(request) }
      twice.each do |receipt|
        expect_retained(receipt)
        expect(receipt.error.cause).to be_a(Phronomy::BackpressureError)
      end
      waiting.release << true
      result_of(occupied)
      result_of(queued)
      eventually { @runtime.offload.active_count.zero? && @runtime.offload.queue_depth.zero? }

      expect_released(result_of(request))
    end

    it "keeps the legacy fixed-keyword submit contract for #{kind}" do
      setup_recovery(kind)
      original = @environment.method(:submit)
      submissions = 0
      @environment.define_singleton_method(:submit) do |on_full:, &work|
        submissions += 1
        original.call(on_full: on_full, &work)
      end

      expect_released(result_of(request))
      expect(submissions).to eq(1)
    end

    it "does not retry legacy #{kind} after ArgumentError loses an accepted handle" do
      setup_recovery(kind)
      waiting, occupied = occupy_worker
      original = @environment.method(:submit)
      accepted = Queue.new
      submissions = 0
      @environment.define_singleton_method(:submit) do |on_full:, &work|
        submissions += 1
        accepted << original.call(on_full: on_full, &work)
        raise ArgumentError, "legacy wrapper lost an accepted handle"
      end

      expect_retained(result_of(request))
      hidden = take(accepted)
      expect_lane_retained
      expect(submissions).to eq(1)
      waiting.release << true
      result_of(occupied)
      result_of(hidden)
      expect_lane_retained
      expect(submissions).to eq(1)
    end

    %i[on_complete on_physical_complete].each do |registration|
      it "retains the #{kind} handle after #{registration} registration fails" do
        setup_recovery(kind)
        waiting, occupied = occupy_worker
        accepted = Queue.new
        submissions = 0
        allow(@environment).to receive(:submit).and_wrap_original do |original, **options, &work|
          submissions += 1
          original.call(**options, &work).tap do |task|
            allow(task).to receive(registration).and_raise(IOError, "recovery callback registration failed")
            accepted << task
          end
        end

        expect_retained(result_of(request))
        hidden = take(accepted)
        expect(hidden.physical_complete?).to be(false)
        blocked = (kind == :reconcile) ? :retry : :reconcile
        expect_retained(result_of(request(blocked)))
        second = request
        if registration == :on_complete
          expect { second.wait_result(timeout: 0.01) }.to raise_error(Phronomy::TimeoutError)
        else
          expect_retained(result_of(second))
        end
        expect(submissions).to eq(1)
        waiting.release << true
        result_of(occupied)
        result_of(hidden)

        expect_released(result_of((registration == :on_complete) ? second : request))
        expect(submissions).to eq(1)
      end
    end
  end
end
