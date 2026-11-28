# frozen_string_literal: true

require "spec_helper"
require "timeout"
require_relative "../../integration/support/llm_stub"
require_relative "../../fixtures/initial_preparation_recovery/application"

RSpec.describe "Initial preparation recovery through the original Runtime" do
  before do
    RubyLLM.configure do |configuration|
      configuration.openai_protocol = :chat_completions
      configuration.openai_api_key = "test"
    end
    @runtime = Phronomy::Runtime.instance
    @gates = []
    @counts = {}
  end

  after do
    @gates.each { |gate| gate.fetch(:release) << true }
    @runtime.shutdown(timeout: 0.03, cancel_grace: 0.2)
    LLMStub.deactivate
  end

  def result_of(task) = task.wait_result(timeout: 8)

  def open_case(handoff: false, transfer: false, output: "case-42 completed")
    @session = InitialPreparationApplication.open_session(handoff: handoff)
    @source = @session.fetch(:source)
    @target = @session.fetch(:target)
    @session.fetch(:agents).each_value do |agent|
      count = @counts[agent.agent_id] = {filter: 0, hook: 0, policy: 0}
      policy = Class.new(Phronomy::Context::ContextPolicy) do
        define_method(:call) do |input|
          count[:policy] += 1
          Phronomy::Context::DefaultPolicy.instance.call(input)
        end
      end.new
      agent.class.context_policy(policy)
      allow(agent).to receive(:run_input_filters!).and_wrap_original do |original, input|
        count[:filter] += 1
        original.call(input)
      end
      allow(agent).to receive(:run_before_llm_input_hooks).and_wrap_original do |original, **options|
        count[:hook] += 1
        original.call(**options)
      end
    end
    responses = []
    if transfer
      binding = Phronomy::MultiAgent::HandoffCapabilityFactory.build(@session.fetch(:edge))
      responses << LLMStub.tool_call_response(binding.tool_name, {responsibility: "Finish case-42"})
    end
    responses << output
    @recorder = LLMStub.activate(responses: responses)
    @session
  end

  def configure_fault(stage:, mode:, agent: @source, reject_filter: false)
    if reject_filter
      count = @counts.fetch(agent.agent_id)
      allow(agent).to receive(:run_input_filters!) do |_input|
        count[:filter] += 1
        raise ArgumentError, "intake rejected case-42"
      end
    end
    boundaries = {admit_execution: :admission, commit_preparation: :activation,
                  commit_preparation_failure: :failure}
    boundaries.each do |method, boundary|
      allow_any_instance_of(Phronomy::Agent::InitialPreparation).to receive(method).and_wrap_original do |original, *args, **options, &work|
        previous = Thread.current[:initial_recovery_application_boundary]
        current = original.receiver.instance_variable_get(:@agent)
        Thread.current[:initial_recovery_application_boundary] = [current.agent_id, boundary]
        original.call(*args, **options, &work)
      ensure
        Thread.current[:initial_recovery_application_boundary] = previous
      end
    end
    @fault = {armed: true, writes: 0, stage: stage, mode: mode}
    allow(@session.fetch(:stores).agent.coordinator).to receive(:atomic).and_wrap_original do |original, *args, &transaction|
      selected = Thread.current[:initial_recovery_application_boundary] == [agent.agent_id, stage]
      next original.call(*args, &transaction) unless selected && @fault[:armed]
      @fault[:armed] = false
      @fault[:writes] += 1
      if mode == :pre
        original.call(*args) do |scope|
          transaction.call(scope)
          raise IOError, "initial #{stage} rolled back and response lost"
        end
      else
        original.call(*args, &transaction)
        raise IOError, "initial #{stage} committed and response lost"
      end
    end
  end

  def start_uncertain(agent: @source, invocation_context: nil, **options)
    @original = @source.invoke_async("case-42", config: @session.fetch(:config),
      invocation_context: invocation_context, **options)
    expect { result_of(@original) }.to raise_error(Phronomy::Agent::InitialPreparationRecoveryError) do |error|
      @original_error = error
      @recovery = error.recovery
    end
    expect(@recovery.agent_id).to eq(agent.agent_id)
    expect(agent.pending_initial_preparation_recovery).to equal(@recovery)
    expect(agent.__execution_environment.registry.agent_execution_admitted?(agent.agent_id)).to be(true)
    expect { agent.unload! }.to raise_error(Phronomy::AgentBusyError)
    @recovery
  end

  def start_handoff_uncertain(agent: @source)
    expect { Timeout.timeout(8) { @session.fetch(:runner).invoke("case-42", config: @session.fetch(:config)) } }
      .to raise_error(Phronomy::Agent::InitialPreparationRecoveryError) do |error|
        @original_error, @recovery = error, error.recovery
      end
    expect(@recovery.agent_id).to eq(agent.agent_id)
    expect(agent.pending_initial_preparation_recovery).to equal(@recovery)
    @recovery
  end

  def recover(agent: @source, retry_pre: true)
    receipt = agent.reconcile_initial_preparation(recovery: @recovery)
    if receipt.outcome == :confirmed_pre && retry_pre
      expect(receipt).not_to be_resolved
      receipt = agent.retry_initial_preparation(recovery: @recovery)
    end
    receipt
  end

  def recovery_diagnostic(receipt)
    details = ["fault=#{@fault.inspect}", "stage=#{receipt.stage} outcome=#{receipt.outcome}"]
    details << @original_error.original_error.full_message if @original_error
    error = receipt.error
    while error
      details << error.full_message
      error = error.cause
    end
    details.join("\n")
  end

  def owner_barrier(agent = @source, &action)
    completion = Phronomy::TaskResult.deferred(name: "initial-recovery-owner-barrier")
    receiver = Object.new
    receiver.define_singleton_method(:deliver_on_event_loop) { |_message| completion.complete(action ? action.call : true) }
    agent.__execution_environment.registry.post(Struct.new(:coordinator).new(receiver), completion: completion)
    result_of(completion)
  end

  [:admission, :activation, :failure].product([:pre, :post]).each do |stage, mode|
    it "recovers #{stage} #{mode} through the original admission without replaying preparation" do
      open_case
      configure_fault(stage: stage, mode: mode, reject_filter: stage == :failure)
      start_uncertain
      before = @counts.fetch(@source.agent_id).dup
      expect(@recorder.calls).to be_empty
      receipt = @source.reconcile_initial_preparation(recovery: @recovery)
      if mode == :pre
        expect(receipt.outcome).to eq(:confirmed_pre), recovery_diagnostic(receipt)
        expect(receipt).not_to be_resolved
        expect(@recorder.calls).to be_empty
        expect(@counts.fetch(@source.agent_id)).to eq(before)
        receipt = @source.retry_initial_preparation(recovery: @recovery)
      end
      expect(receipt).to be_resolved, recovery_diagnostic(receipt)
      expect(receipt.application_state).to eq(:applied)
      saved = result_of(receipt.execution_task)
      expect(saved[:execution_id]).to eq(@recovery.execution_id)
      expect(@source.persistence.executions.list(@source.agent_id).map(&:execution_id)).to eq([@recovery.execution_id])
      expect(@source.pending_initial_preparation_recovery).to be_nil
      expect { result_of(@original) }.to raise_error(@original_error)
      if stage == :failure
        expect(saved).to include(status: :failed, error: include("message" => "intake rejected case-42"))
        expect(receipt.continuation_state).to eq(:stopped)
        expect(@recorder.calls).to be_empty
        expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 0, policy: 0)
      else
        expect(saved).to include(status: :completed, output: "case-42 completed")
        expect(receipt.continuation_state).to eq(:resumed)
        expect(@recorder.calls.size).to eq(1)
        expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 1, policy: 1)
      end
      expect(@source.__execution_environment.registry.agent_execution_admitted?(@source.agent_id)).to be(false)
      expect(@fault[:writes]).to eq(1)
    end
  end

  it "keeps the same capability through successive admission and activation response losses" do
    open_case
    configure_fault(stage: :admission, mode: :post)
    start_uncertain
    original_recovery = @recovery
    expect(@counts.fetch(@source.agent_id)).to eq(filter: 0, hook: 0, policy: 0)
    configure_fault(stage: :activation, mode: :post)
    first = @source.reconcile_initial_preparation(recovery: original_recovery)
    expect(first).not_to be_resolved
    expect(first.stage).to eq(:activation)
    expect(@source.pending_initial_preparation_recovery).to equal(original_recovery)
    expect(@recorder.calls).to be_empty
    expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 1, policy: 1)
    second = @source.reconcile_initial_preparation(recovery: original_recovery)
    expect(second).to be_resolved
    expect(result_of(second.execution_task)).to include(execution_id: original_recovery.execution_id,
      status: :completed, output: "case-42 completed")
    expect(@recorder.calls.size).to eq(1)
    expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 1, policy: 1)
    expect(@source.persistence.executions.list(@source.agent_id).size).to eq(1)
  end

  it "releases the original initial slot after confirming saved failure so a genuinely new request can start" do
    open_case
    configure_fault(stage: :failure, mode: :post, reject_filter: true)
    start_uncertain
    saved = result_of(recover.execution_task)
    expect(saved[:status]).to eq(:failed)
    allow(@source).to receive(:run_input_filters!).and_call_original
    next_result = result_of(@source.invoke_async("another case"))
    expect(next_result).to include(output: "case-42 completed")
    expect(next_result[:execution_id]).not_to eq(@recovery.execution_id)
    expect(@recorder.calls.size).to eq(1)
  end

  [:source, :reserved_target].product([:pre, :post]).each do |owner, mode|
    it "recovers a #{owner} initial save in the same Handoff chain after #{mode} uncertainty" do
      open_case(handoff: true, transfer: owner == :reserved_target)
      agent = (owner == :source) ? @source : @target
      configure_fault(stage: :activation, mode: mode, agent: agent)
      start_handoff_uncertain(agent: agent)
      calls_before = (owner == :source) ? 0 : 1
      expect(@recorder.calls.size).to eq(calls_before)
      receipt = recover(agent: agent)
      expect(receipt).to be_resolved, recovery_diagnostic(receipt)
      result_of(receipt.execution_task)
      result = @session.fetch(:runner).resume(@recovery.execution_id, config: @session.fetch(:config))
      expect(result).to include(status: :completed, output: "case-42 completed", agent: agent)
      expect(@session.fetch(:runner).resume(@recovery.execution_id)).to eq(result)
      expect(@recorder.calls.size).to eq(calls_before + 1)
      expect(@counts.fetch(agent.agent_id)).to eq(filter: 1, hook: 1, policy: 1)
      expect(agent.persistence.executions.list(agent.agent_id).size).to eq(1)
    end
  end

  it "cleans a reserved terminal failure even when the exact observer already returned the saved value" do
    open_case
    configure_fault(stage: :failure, mode: :post, reject_filter: true)
    reservation = Phronomy::Agent::ReservedExecution.new(agent_id: @source.agent_id,
      execution_id: "reserved-initial-failure")
    saved = result_of(@source.start_reserved_async(reservation: reservation, input: "case-42"))
    expect(saved).to include(status: :failed, execution_id: reservation.execution_id)
    @recovery = @source.pending_initial_preparation_recovery
    expect(@recovery).not_to be_nil
    expect(@recovery.execution_id).to eq(reservation.execution_id)
    expect(@source.__execution_environment.registry.agent_execution_admitted?(@source.agent_id)).to be(true)
    receipt = recover
    expect(receipt).to be_resolved, recovery_diagnostic(receipt)
    expect(result_of(receipt.execution_task)).to include(status: :failed)
    expect(@source.__execution_environment.registry.agent_execution_admitted?(@source.agent_id)).to be(false)
    expect(@recorder.calls).to be_empty
    expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 0, policy: 0)
  end

  it "discovers and cleans a reserved Handoff Target failure while preserving the saved business error" do
    session = open_case(handoff: true, transfer: true)
    configure_fault(stage: :failure, mode: :post, agent: @target, reject_filter: true)
    expect { InitialPreparationApplication::After.start(session, "case-42") }
      .to raise_error(Phronomy::Error, "ArgumentError: intake rejected case-42")
    target_execution = @target.persistence.executions.list(@target.agent_id).fetch(0)
    expect(target_execution.status).to eq(:failed)
    expect(@target.pending_initial_preparation_recovery).to be_nil
    expect(@target.__execution_environment.registry.agent_execution_admitted?(@target.agent_id)).to be(false)
    expect(@recorder.calls.size).to eq(1)
    expect(@counts.fetch(@target.agent_id)).to eq(filter: 1, hook: 0, policy: 0)
  end

  it "keeps an unreadable initial proof retained and waits for restored authoritative reads" do
    open_case
    configure_fault(stage: :activation, mode: :post)
    start_uncertain
    coordinator = @session.fetch(:stores).agent.coordinator
    allow(coordinator).to receive(:atomic).and_raise(IOError, "initial proof unavailable")
    receipt = @source.reconcile_initial_preparation(recovery: @recovery)
    expect(receipt.outcome).to eq(:unavailable)
    expect(receipt).not_to be_resolved
    expect(@source.pending_initial_preparation_recovery).to equal(@recovery)
    expect(@recorder.calls).to be_empty
    allow(coordinator).to receive(:atomic).and_call_original
    expect(result_of(recover.execution_task)).to include(output: "case-42 completed")
    expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 1, policy: 1)
  end

  it "does not retry a captured initial save after current Handoff routing changes" do
    open_case(handoff: true)
    configure_fault(stage: :activation, mode: :pre)
    start_handoff_uncertain
    routing_store = @session.fetch(:stores).multi_agent.handoff_states
    route = routing_store.load(@source.agent_id)
    routing_store.save(@source.agent_id, expected_revision: route.handoff_revision,
      state: route.with(metadata: route.metadata.merge("new_authority" => true)))
    receipt = @source.retry_initial_preparation(recovery: @recovery)
    expect(receipt).not_to be_resolved
    expect(@recorder.calls).to be_empty
    expect(@source.pending_initial_preparation_recovery).to equal(@recovery)
    expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 1, policy: 1)
  end

  it "keeps one delayed proof worker when one recovery observer cancels" do
    open_case
    configure_fault(stage: :activation, mode: :post)
    start_uncertain
    gate = {entered: Queue.new, release: Queue.new}
    @gates << gate
    reads = 0
    allow(@session.fetch(:stores).agent.coordinator).to receive(:atomic).and_wrap_original do |original, *args, &transaction|
      reads += 1
      if reads == 1
        gate.fetch(:entered) << true
        gate.fetch(:release).pop
      end
      original.call(*args, &transaction)
    end
    first = @source.reconcile_initial_preparation_async(recovery: @recovery)
    Timeout.timeout(8) { gate.fetch(:entered).pop }
    second = @source.reconcile_initial_preparation_async(recovery: @recovery)
    first.cancel!
    owner_barrier
    expect(second).not_to be_done
    expect(reads).to eq(1)
    expect(@source.__execution_environment.registry.agent_execution_admitted?(@source.agent_id)).to be(true)
    expect(@recorder.calls).to be_empty
    gate.fetch(:release) << true
    receipt = result_of(second)
    expect { result_of(first) }.to raise_error(Phronomy::CancellationError)
    expect(result_of(receipt.execution_task)).to include(output: "case-42 completed")
    expect(@recorder.calls.size).to eq(1)
    expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 1, policy: 1)
  end

  [:admission, :activation].each do |stage|
    it "resolves #{stage} pre-state after direct parent cancellation without saving the cancelled proposal" do
      open_case
      configure_fault(stage: stage, mode: :pre)
      start_uncertain
      before = @counts.fetch(@source.agent_id).dup
      @session.fetch(:config).fetch(:cancellation_token).cancel!
      receipt = @source.reconcile_initial_preparation(recovery: @recovery)
      expect(receipt).to be_resolved, recovery_diagnostic(receipt)
      expect(receipt.application_state).to eq(:applied)
      expect(receipt.continuation_state).to eq(:stopped)
      if stage == :admission
        expect(receipt.outcome).to eq(:confirmed_pre)
        expect { result_of(receipt.execution_task) }.to raise_error(Phronomy::CancellationError)
        expect(@source.persistence.executions.list(@source.agent_id)).to be_empty
      else
        expect(result_of(receipt.execution_task)).to include(status: :cancelled)
        expect(@source.persistence.executions.list(@source.agent_id).size).to eq(1)
      end
      expect(@source.pending_initial_preparation_recovery).to be_nil
      expect(@source.__execution_environment.registry.agent_execution_admitted?(@source.agent_id)).to be(false)
      expect(@counts.fetch(@source.agent_id)).to eq(before)
      expect(@recorder.calls).to be_empty
      expect(@fault[:writes]).to eq(1)
      expect { result_of(@original) }.to raise_error(@original_error)
    end
  end

  [:pre, :post].each do |mode|
    it "preserves the captured business failure after failure #{mode} uncertainty and later cancellation" do
      open_case
      configure_fault(stage: :failure, mode: mode, reject_filter: true)
      start_uncertain
      @session.fetch(:config).fetch(:cancellation_token).cancel!
      receipt = recover
      expect(receipt).to be_resolved, recovery_diagnostic(receipt)
      expect(result_of(receipt.execution_task)).to include(status: :failed,
        error: include("class" => "ArgumentError", "message" => "intake rejected case-42"))
      expect(@source.pending_initial_preparation_recovery).to be_nil
      expect(@source.__execution_environment.registry.agent_execution_admitted?(@source.agent_id)).to be(false)
      expect(@recorder.calls).to be_empty
      expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 0, policy: 0)
    end
  end

  it "observes the recovered structured output without submitting captured internal config as a new public resume" do
    open_case(output: '{"answer":"case-42 completed"}')
    configure_fault(stage: :activation, mode: :post)
    schema = {type: "object", properties: {answer: {type: "string"}}, required: ["answer"]}
    start_uncertain(output_schema: schema)
    receipt = recover
    expect(receipt).to be_resolved, recovery_diagnostic(receipt)
    result = result_of(receipt.execution_task)
    expect(result).to include(status: :completed, output: {"answer" => "case-42 completed"})
    expect(@recorder.calls.size).to eq(1)
    expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 1, policy: 1)
    observed = @source.reconcile_initial_preparation(recovery: @recovery)
    expect(observed.execution_task).not_to equal(receipt.execution_task)
    expect(result_of(observed.execution_task)).to eq(result)
    expect(@recorder.calls.size).to eq(1)
  end

  it "retains original parent cancellation after the initial failed observation has closed" do
    open_case
    configure_fault(stage: :activation, mode: :post)
    parent = Phronomy::Concurrency::CancellationToken.new
    context = Phronomy::InvocationContext.new(cancellation_token: parent)
    start_uncertain(invocation_context: context)
    expect(@original).to be_done
    parent.cancel!
    receipt = recover
    expect(receipt).to be_resolved, recovery_diagnostic(receipt)
    expect(result_of(receipt.execution_task)).to include(status: :cancelled)
    expect(@recorder.calls).to be_empty
    expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 1, policy: 1)
  end

  it "retains the original deadline subscription after the initial failed observation has closed" do
    open_case
    configure_fault(stage: :activation, mode: :post)
    deadline = Phronomy::Concurrency::Deadline.in(3)
    context = Phronomy::InvocationContext.new(deadline: deadline)
    start_uncertain(invocation_context: context)
    expect(@original).to be_done
    Timeout.timeout(6) do
      sleep 0.01 until deadline.expired?
    end
    receipt = recover
    expect(receipt).to be_resolved, recovery_diagnostic(receipt)
    expect(result_of(receipt.execution_task)).to include(status: :cancelled)
    expect(@recorder.calls).to be_empty
  end

  it "rediscovers retained preparation after its original Ready notification is refused" do
    open_case
    registry = @source.__execution_environment.registry
    ready_type = Phronomy::Agent::InitialPreparationRecoveryOperation.const_get(:Ready)
    refused = 0
    refused_message = nil
    allow(registry).to receive(:post).and_wrap_original do |original, message, **options|
      if message.is_a?(ready_type) && refused.zero?
        refused += 1
        refused_message = message
        false
      else
        original.call(message, **options)
      end
    end
    @original = @source.invoke_async("case-42", config: @session.fetch(:config))
    expect { result_of(@original) }.to raise_error(Phronomy::Error)
    @recovery = @source.pending_initial_preparation_recovery
    expect(@recovery).not_to be_nil
    expect(refused).to eq(1)
    registry.post(refused_message)
    owner_barrier
    expect(@source.pending_initial_preparation_recovery).to equal(@recovery)
    expect(@recorder.calls).to be_empty
    receipt = recover
    expect(receipt).to be_resolved, recovery_diagnostic(receipt)
    expect(result_of(receipt.execution_task)).to include(output: "case-42 completed")
    expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 1, policy: 1)
    expect(@recorder.calls.size).to eq(1)
  end

  [false, true].each do |lose_response|
    it "preserves an opaque admission callback with response_loss=#{lose_response}" do
      open_case
      admission_calls = 0
      participant = Object.new
      participant.define_singleton_method(:admit) do |admission|
        admission_calls += 1
        admission.accept
        raise IOError, "opaque admission callback response lost" if lose_response
      end
      reservation = Phronomy::Agent::ReservedExecution.new(agent_id: @source.agent_id,
        execution_id: "opaque-initial-application", correlation: {"owner" => "application-owner"})
      @original = @source.start_reserved_async(reservation: reservation, input: "case-42",
        config: @session.fetch(:config).merge(phronomy_admission: participant))
      if lose_response
        expect { result_of(@original) }.to raise_error(Phronomy::Agent::InitialPreparationRecoveryError) do |error|
          @original_error, @recovery = error, error.recovery
        end
        expect(@source.pending_initial_preparation_recovery).to equal(@recovery)
        [:reconcile_initial_preparation, :retry_initial_preparation].each do |operation|
          receipt = @source.public_send(operation, recovery: @recovery)
          expect(receipt.outcome).to eq(:unavailable)
          expect(receipt).not_to be_resolved
        end
        expect(@source.persistence.executions.load(reservation.execution_id).status).to eq(:preparing)
        expect(@source.__execution_environment.registry.agent_execution_admitted?(@source.agent_id)).to be(true)
        expect(@recorder.calls).to be_empty
        expect(@counts.fetch(@source.agent_id)).to eq(filter: 0, hook: 0, policy: 0)
      else
        expect(result_of(@original)).to include(status: :completed, execution_id: reservation.execution_id,
          output: "case-42 completed")
        expect(@source.pending_initial_preparation_recovery).to be_nil
        expect(@recorder.calls.size).to eq(1)
        expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 1, policy: 1)
      end
      expect(admission_calls).to eq(1)
      expect(@source.persistence.executions.list(@source.agent_id).size).to eq(1)
    end
  end

  it "retains unsupported opaque preparation after a successful worker loses its Ready notification" do
    open_case
    admission_calls = 0
    participant = Object.new
    participant.define_singleton_method(:admit) do |admission|
      admission_calls += 1
      admission.accept
    end
    registry = @source.__execution_environment.registry
    ready_type = Phronomy::Agent::InitialPreparationRecoveryOperation.const_get(:Ready)
    refused = 0
    allow(registry).to receive(:post).and_wrap_original do |original, message, **options|
      if message.is_a?(ready_type) && refused.zero?
        refused += 1
        false
      else
        original.call(message, **options)
      end
    end
    reservation = Phronomy::Agent::ReservedExecution.new(agent_id: @source.agent_id,
      execution_id: "opaque-prepared-notification-loss", correlation: {"owner" => "application-owner"})
    @original = @source.start_reserved_async(reservation: reservation, input: "case-42",
      config: @session.fetch(:config).merge(phronomy_admission: participant))
    expect { result_of(@original) }.to raise_error(Phronomy::Agent::InitialPreparationRecoveryError) do |error|
      @original_error, @recovery = error, error.recovery
    end
    expect(@source.persistence.executions.load(reservation.execution_id).status).to eq(:active)
    [:reconcile_initial_preparation, :retry_initial_preparation].each do |operation|
      receipt = @source.public_send(operation, recovery: @recovery)
      expect(receipt.outcome).to eq(:unavailable)
      expect(receipt).not_to be_resolved
    end
    expect(@source.pending_initial_preparation_recovery).to equal(@recovery)
    expect(registry.agent_execution_admitted?(@source.agent_id)).to be(true)
    expect(registry.agent_execution_owner(reservation.execution_id)).to be_nil
    expect(refused).to eq(1)
    expect(admission_calls).to eq(1)
    expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 1, policy: 1)
    expect(@recorder.calls).to be_empty
    expect { result_of(@original) }.to raise_error(@original_error)
  end

  it "removes only the positively unadmitted initial projection when late cancellation saves its terminal result" do
    open_case
    environment = @source.__execution_environment
    refused_sessions = []
    allow(environment).to receive(:register_session) do |session, **_options|
      refused_sessions << session.id
      raise Phronomy::RuntimeShutdownError, "initial session registration positively refused"
    end
    start_uncertain
    expect(refused_sessions.size).to eq(1)
    expect(environment.session_admitted?(refused_sessions.first)).to be(false)
    expect(environment.registry.agent_execution_owner(@recovery.execution_id)).not_to be_nil
    expect(@recorder.calls).to be_empty
    @session.fetch(:config).fetch(:cancellation_token).cancel!
    receipt = recover
    expect(receipt).to be_resolved, recovery_diagnostic(receipt)
    expect(receipt.continuation_state).to eq(:stopped)
    expect(result_of(receipt.execution_task)).to include(status: :cancelled,
      execution_id: @recovery.execution_id)
    expect(environment.registry.agent_execution_owner(@recovery.execution_id)).to be_nil
    expect(environment.registry.agent_execution_admitted?(@source.agent_id)).to be(false)
    expect(@source.pending_initial_preparation_recovery).to be_nil
    expect(@source.persistence.executions.list(@source.agent_id).size).to eq(1)
    expect(refused_sessions.size).to eq(1)
    expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 1, policy: 1)
    expect(@recorder.calls).to be_empty
    expect { result_of(@original) }.to raise_error(@original_error)
    expect(@source.unload!).to be(true)
  end

  [:bind_initial_preparation, :install_agent_execution].each do |boundary|
    it "reuses the same initial session after #{boundary} succeeds but its response is lost" do
      open_case
      environment = @source.__execution_environment
      sessions = []
      allow(environment).to receive(:build_agent_session).and_wrap_original do |original, **options|
        original.call(**options).tap { |session| sessions << session.id }
      end
      attempts = 0
      allow(environment.registry).to receive(boundary).and_wrap_original do |original, *args, **options|
        value = original.call(*args, **options)
        attempts += 1
        raise IOError, "initial application response lost after #{boundary}" if attempts == 1
        value
      end
      start_uncertain
      expect(@recorder.calls).to be_empty
      expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 1, policy: 1)
      receipt = recover
      expect(receipt).to be_resolved, recovery_diagnostic(receipt)
      expect(result_of(receipt.execution_task)).to include(status: :completed,
        execution_id: @recovery.execution_id, output: "case-42 completed")
      expect(sessions.size).to eq(1)
      expect(@source.persistence.executions.list(@source.agent_id).size).to eq(1)
      expect(@source.pending_initial_preparation_recovery).to be_nil
      expect(@recorder.calls.size).to eq(1)
      expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 1, policy: 1)
      expect { result_of(@original) }.to raise_error(@original_error)
    end
  end

  it "confirms the exact admitted session after its registration response is lost" do
    open_case
    environment = @source.__execution_environment
    registered = []
    allow(environment).to receive(:register_session).and_wrap_original do |original, session, **options|
      value = original.call(session, **options)
      registered << session.id
      raise IOError, "initial session registration response lost" if registered.size == 1
      value
    end
    result = result_of(@source.invoke_async("case-42", config: @session.fetch(:config)))
    expect(result).to include(output: "case-42 completed")
    expect(registered.size).to eq(1)
    expect(@source.pending_initial_preparation_recovery).to be_nil
    expect(@source.__execution_environment.registry.agent_execution_admitted?(@source.agent_id)).to be(false)
    expect(@source.persistence.executions.list(@source.agent_id).size).to eq(1)
    expect(@recorder.calls.size).to eq(1)
    expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 1, policy: 1)
  end

  it "keeps the execution observation available after the complete application's waiter timeout" do
    session = open_case
    configure_fault(stage: :activation, mode: :post)
    start_uncertain
    gate = {entered: Queue.new, release: Queue.new}
    @gates << gate
    allow(@recorder).to receive(:handle).and_wrap_original do |original, request|
      gate.fetch(:entered) << true
      gate.fetch(:release).pop
      original.call(request)
    end
    receipt = recover
    expect(receipt).to be_resolved, recovery_diagnostic(receipt)
    Timeout.timeout(8) { gate.fetch(:entered).pop }
    pending = {state: :recovery_pending, recovery: @recovery, receipt: receipt}
    timed_out = InitialPreparationApplication::After.finish(session, pending, wait_timeout: 0.01)
    expect(timed_out[:state]).to eq(:execution_observation_pending)
    expect(receipt.execution_task).not_to be_done
    gate.fetch(:release) << true
    finished = InitialPreparationApplication::After.finish(session, timed_out, wait_timeout: 8)
    expect(finished).to include(state: :terminal, result: include(output: "case-42 completed"))
    expect(@recorder.calls.size).to eq(1)
    expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 1, policy: 1)
    InitialPreparationApplication.close_completed_session(session)
  end

  [InitialPreparationApplication::Before, InitialPreparationApplication::After].each do |application|
    [false, true].each do |handoff|
      it "executes the complete #{application.name.split("::").last} normal application with handoff=#{handoff}" do
        session = open_case(handoff: handoff)
        result = application.run(session, "case-42")
        expect(result).to include(output: "case-42 completed")
        expect(@recorder.calls.size).to eq(1)
        expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 1, policy: 1)
        InitialPreparationApplication.close_completed_session(session)
      end
    end
  end

  it "executes the complete driver and keeps the completed session available for explicit cleanup" do
    LLMStub.activate(responses: ["case-42 completed"])
    application = InitialPreparationApplication.run_example("case-42", handoff: true)
    expect(application.fetch(:observation)).to include(state: :terminal,
      result: include(output: "case-42 completed"))
    InitialPreparationApplication.close_completed_session(application.fetch(:session))
  end

  it "returns the session with the complete driver's application error so the caller retains cleanup custody" do
    session = open_case(handoff: true, transfer: true)
    allow(InitialPreparationApplication).to receive(:open_session).with(handoff: true).and_return(session)
    configure_fault(stage: :failure, mode: :post, agent: @target, reject_filter: true)
    application = InitialPreparationApplication.run_example("case-42", handoff: true)
    expect(application.fetch(:session)).to equal(session)
    observation = application.fetch(:observation)
    expect(observation[:state]).to eq(:application_error)
    expect(observation[:error]).to be_a(Phronomy::Error)
    expect(observation[:error].message).to eq("ArgumentError: intake rejected case-42")
    expect(@target.pending_initial_preparation_recovery).to be_nil
    expect(@target.__execution_environment.registry.agent_execution_admitted?(@target.agent_id)).to be(false)
    expect(@recorder.calls.size).to eq(1)
    routing = session.fetch(:stores).multi_agent.handoff_states.load(@source.agent_id)
    expect(routing.phase).not_to eq("stable")
    expect { InitialPreparationApplication.close_completed_session(session) }
      .to raise_error(Phronomy::AgentBusyError, "Handoff history retains unfinished work")
    expect(application.fetch(:session)).to equal(session)
  end

  it "executes the complete recovery application with explicit retry and a separate pending policy" do
    session = open_case
    configure_fault(stage: :activation, mode: :pre)
    pending = InitialPreparationApplication::After.start(session, "case-42")
    expect(pending[:state]).to eq(:recovery_pending)
    expect(pending.fetch(:receipt).outcome).to eq(:confirmed_pre)
    expect(@recorder.calls).to be_empty
    result = InitialPreparationApplication::After.recover(session, pending.fetch(:recovery), retry_confirmed_pre: true)
    expect(result).to include(state: :terminal, result: include(output: "case-42 completed"))
    expect(@recorder.calls.size).to eq(1)
    expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 1, policy: 1)
    InitialPreparationApplication.close_completed_session(session)
  end
end
