# frozen_string_literal: true

RSpec.shared_context "a correlated child with uncertain persistence" do
  require_relative "../integration/support/hosted_subagent"

  include_context "a native child requiring approval"

  let(:effects) { [] }
  let(:child_tool) do
    results = effects
    behavior = -> { @child_behavior&.call }
    Class.new(Phronomy::Tool::Base) do
      tool_name "child_recovery_action"
      description "Records the one child action"
      param :input, type: :string, desc: "Action input"
      on_error :raise
      define_method(:execute) do |input:|
        results << input
        behavior.call
        "child action completed"
      end
    end
  end
  let(:child_class) { IntegrationFactors.agent_class("base", tools: [child_tool]) }

  before do
    RubyLLM.configure do |configuration|
      configuration.openai_protocol = :chat_completions
      configuration.openai_api_key = "test"
    end
  end

  after do
    @child_gates&.each { |waiting| waiting.fetch(:release) << true }
    @child_runtime&.shutdown(timeout: 0.03, cancel_grace: 0.2)
  end

  def child_result(task) = task.wait_result(timeout: 8)
  def child_take(queue) = Timeout.timeout(8) { queue.pop }

  def child_eventually
    Timeout.timeout(8) do
      loop do
        found = yield
        return found if found
        sleep 0.002
      end
    end
  end

  def child_gate
    {entered: Queue.new, release: Queue.new}.tap { |waiting| (@child_gates ||= []) << waiting }
  end

  def configure_child_recovery(kind:, mode: :post, behavior: nil)
    @child_kind, @child_behavior = kind, behavior
    @child_recorder = LLMStub.activate(responses: [dispatch,
      LLMStub.tool_call_response("child_recovery_action", {input: "once"}),
      "child completed", "parent completed"])
    @child_runtime = Phronomy::Runtime.instance
    allow_any_instance_of(child_class).to receive(:start_reserved_async).and_wrap_original do |original, **options|
      @recovery_child = original.receiver
      @child_started_execution_id = options.fetch(:reservation).execution_id
      original.call(**options).tap { |task| @child_original ||= task }
    end
    @child_fault = {armed: mode != :none, readback: false, writes: 0}
    allow_any_instance_of(Phronomy::Agent::ExecutionChange).to receive(:perform).and_wrap_original do |original|
      change = original.receiver
      updated = change.instance_variable_get(:@updated)
      target = change.correlation && ((kind == :terminal && change.kind == :terminal) ||
        (kind == :provider && change.kind == :dispatch && updated&.phase == :calling_llm) ||
        (kind == :tool && change.kind == :dispatch && updated&.phase == :dispatching_tools))
      if target && @child_fault[:armed]
        @child_execution_id = change.execution_id
        if @child_fault[:capture_cancellation]
          stores.agent.request_cancellation(agent_id: change.agent_id, execution_id: change.execution_id)
        end
        @child_before = stores.agent.executions.load(change.execution_id)
      end
      Thread.current[:correlated_child_recovery_fault] = !!target
      original.call
    ensure
      Thread.current[:correlated_child_recovery_fault] = nil
    end
    allow(stores.agent.coordinator).to receive(:atomic).and_wrap_original do |original, *args, &transaction|
      if Thread.current[:correlated_child_recovery_fault] && @child_fault[:readback]
        @child_fault[:readback] = false
        raise IOError, "child immediate readback unavailable"
      end
      unless Thread.current[:correlated_child_recovery_fault] && @child_fault[:armed]
        next original.call(*args, &transaction)
      end
      @child_fault[:armed] = false
      @child_fault[:writes] += 1
      if (waiting = @child_fault.delete(:save_gate))
        waiting.fetch(:entered) << true
        waiting.fetch(:release).pop
      end
      if mode == :pre
        original.call(*args) do |scope|
          transaction.call(scope)
          @child_fault[:readback] = true
          raise IOError, "child transaction rolled back and response lost"
        end
      else
        original.call(*args, &transaction)
        @child_fault[:readback] = true
        raise IOError, "child transaction committed and response lost"
      end
    end
  end

  def start_child_recovery
    reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: root_id)
    @parent_original = parent.start_hosted(reservation: reservation, input: "run", config: {cancellation_token: token})
    child_eventually { @child_original && @child_execution_id }
    @child_registry = @recovery_child.__execution_environment.registry
  end

  def observe_child_recovery
    error_class = (@child_kind == :terminal) ? Phronomy::Agent::TerminalRecoveryError : Phronomy::Agent::DispatchRecoveryError
    begin
      @child_original_result = child_result(@child_original)
      # ExactExecution can fulfill its original public observation from the
      # committed terminal record while the local recovery owner still exists.
      expect(@child_kind).to eq(:terminal)
      expect(stores.agent.executions.load(@child_execution_id)).to be_terminal
      @child_recovery = child_pending_recovery
    rescue error_class => error
      @child_error, @child_recovery = error, error.recovery
    end
    expect(@child_recovery.execution_id).to eq(@child_execution_id)
    expect(child_pending_recovery).to equal(@child_recovery)
    expect_child_owner_retained
  end

  def child_pending_recovery
    method = (@child_kind == :terminal) ? :pending_terminal_recovery : :pending_dispatch_recovery
    @recovery_child.public_send(method, execution_id: @child_execution_id)
  end

  def child_reconcile
    method = (@child_kind == :terminal) ? :reconcile_terminal_async : :reconcile_dispatch_async
    child_result(@recovery_child.public_send(method, recovery: @child_recovery))
  end

  def child_retry
    method = (@child_kind == :terminal) ? :retry_terminal_async : :retry_dispatch_async
    child_result(@recovery_child.public_send(method, recovery: @child_recovery))
  end

  def expect_child_owner_retained(persisted: true)
    expect(@child_registry.agent_execution_admitted?(@recovery_child.agent_id)).to be(true)
    expect { @recovery_child.unload! }.to raise_error(Phronomy::AgentBusyError)
    expect(child_class.get(@recovery_child.agent_id)).to equal(@recovery_child)
    return unless persisted
    expect(stores.agent.retained_references(agent_id: @recovery_child.agent_id)).to include(
      Phronomy::Agent::Retention.new(agent_id: @recovery_child.agent_id, execution_id: @child_execution_id,
        owner_key: "subagent:#{root_id}")
    )
  end

  def expect_child_original_closed
    if @child_original_result
      expect(child_result(@child_original)).to equal(@child_original_result)
    else
      expect { child_result(@child_original) }.to raise_error { |error| expect(error).to equal(@child_error) }
    end
  end

  def child_owner_barrier(&action)
    completion = Phronomy::TaskResult.deferred(name: "child-recovery-owner-barrier")
    receiver = Object.new
    receiver.define_singleton_method(:deliver_on_event_loop) { |_message| completion.complete(action ? action.call : true) }
    @child_registry.post(Struct.new(:coordinator).new(receiver), completion: completion)
    child_result(completion)
  end

  def finish_recovered_parent
    if stores.agent.executions.load(root_id).terminal?
      child_result(@parent_original)
    else
      expect { child_result(@parent_original) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
      parent.resume(root_id)
    end
  end
end
