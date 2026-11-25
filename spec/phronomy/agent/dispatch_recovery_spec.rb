# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe "Agent dispatch recovery through its original Runtime" do
  def result_of(task)
    task.wait_result(timeout: 4)
  end

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

  def gate
    {entered: Queue.new, release: Queue.new}.tap { |value| (@gates ||= []) << value }
  end

  def on_owner(&action)
    result = Phronomy::TaskResult.deferred(name: "dispatch-recovery-observation")
    handler = Object.new
    handler.define_singleton_method(:deliver_on_event_loop) do |_message|
      result.complete(action.call)
    rescue => error
      result.fail(error)
    end
    @registry.post(Struct.new(:coordinator).new(handler), completion: result)
    result_of(result)
  end

  # Only the external response and the persistence fault are synthetic. The
  # Runtime owns admission, preparation, proof, continuation and finalization.
  def setup_dispatch(kind:, mode: :post, final_provider_gate: nil)
    @kind = kind
    calls, effects, hooks, stream_calls = [], [], [], []
    @calls, @effects, @hooks, @stream_calls = calls, effects, hooks, stream_calls
    tool = Class.new(Phronomy::Tool::Base) do
      tool_name "recovered_dispatch_lookup"
      description "Read a deterministic value once"
      param :item, type: :string, desc: "Item identity"
      define_method(:execute) do |item:|
        effects << item
        "found #{item}"
      end
    end
    @agent_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "dispatch-recovery-#{kind}", version: 1
      model "offline-model"
      tools tool => nil
    end
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |request, cancellation_token:|
        cancellation_token&.raise_if_cancelled!
        calls << request
        if calls.size == 1
          Phronomy::LLMAdapter::Response.new(finish_reason: :tool_calls,
            tool_calls: [Phronomy::Tool::CallRequest.new(id: "lookup-1",
              name: "recovered_dispatch_lookup", arguments: {item: "one"})])
        else
          if final_provider_gate
            final_provider_gate.fetch(:entered) << true
            final_provider_gate.fetch(:release).pop
          end
          Phronomy::LLMAdapter::Response.new(content: "recovered answer", finish_reason: :stop)
        end
      end
      define_method(:perform_stream) do |request, cancellation_token:, &notify|
        stream_calls << request
        response = perform_complete(request, cancellation_token: cancellation_token)
        notify.call(Phronomy::LLMAdapter::StreamChunk.new(content: response.content)) if response.content
        response
      end
    end.new
    Phronomy.configure { |config| config.llm_adapter = adapter }
    @store = Phronomy::PersistenceComposition.in_memory.agent
    @events = []
    @agent = @agent_class.create(agent_id: "dispatch-#{kind}-#{RSpec.current_example.metadata.fetch(:line_number)}",
      persistence: @store, on_event: ->(event) { @events << event })
    @agent.before_llm_input = ->(context) {
      hooks << context.call_sequence
      nil
    }
    @runtime = Phronomy::Runtime.instance
    @registry = Phronomy::Agent::ExecutionRegistry.for(@runtime.event_loop)
    @environment = @agent.__execution_environment
    @token = Phronomy::Concurrency::CancellationToken.new
    install_dispatch_fault(kind, mode)
  end

  def install_dispatch_fault(kind, mode)
    fault = @fault = {armed: mode != :none, failed_readback: false, commits: 0}
    phase = (kind == :provider) ? :calling_llm : :dispatching_tools
    allow_any_instance_of(Phronomy::Agent::ExecutionChange).to receive(:perform).and_wrap_original do |method, *args|
      change = method.receiver
      target = change.kind == :dispatch && change.instance_variable_get(:@updated)&.phase == phase
      if target && fault[:armed] && fault[:capture_cancellation]
        @store.request_cancellation(agent_id: @agent.agent_id, execution_id: change.execution_id)
      end
      Thread.current[:g3c_fault_target] = target
      fault[:execution_id] = change.execution_id if target && fault[:armed]
      method.call(*args)
    ensure
      Thread.current[:g3c_fault_target] = nil
    end
    allow(@store.coordinator).to receive(:atomic).and_wrap_original do |method, *args, &block|
      if Thread.current[:g3c_fault_target] && fault[:failed_readback]
        fault[:failed_readback] = false
        raise IOError, "immediate dispatch readback unavailable"
      end
      unless Thread.current[:g3c_fault_target] && fault[:armed]
        next method.call(*args, &block)
      end
      fault[:armed] = false
      fault[:commits] += 1
      if mode == :pre
        method.call(*args) do |scope|
          block.call(scope)
          fault[:failed_readback] = true
          raise IOError, "dispatch proposal rolled back and reply was lost"
        end
      else
        method.call(*args, &block)
        fault[:failed_readback] = true
        raise IOError, "dispatch proposal committed and reply was lost"
      end
    end
  end

  def start_unknown(stream: false)
    entry = stream ? :stream_async : :invoke_async
    @original = @agent.public_send(entry, "lookup one", config: {cancellation_token: @token})
    expect { result_of(@original) }.to raise_error(Phronomy::Agent::DispatchRecoveryError) do |error|
      @original_error = error
      @recovery = error.recovery
    end
    @execution_id = @recovery.execution_id
    expect(@recovery.agent_id).to eq(@agent.agent_id)
    expect(@recovery.dispatch_kind).to eq(@kind)
    expect(@agent.pending_dispatch_recovery(execution_id: @execution_id)).to equal(@recovery)
    expect(@registry.agent_execution_admitted?(@agent.agent_id)).to be(true)
    expect_original_work_only
  end

  def interrupt_preparation_submission(waiting, lose_handle: false)
    target = @kind
    injected = false
    allow_any_instance_of(Phronomy::Agent::DispatchRecoveryOperation).to receive(:start).and_wrap_original do |method|
      Thread.current[:g3c_intercept_submission] = method.receiver.dispatch_kind == target
      method.call
    ensure
      Thread.current[:g3c_intercept_submission] = nil
    end
    allow(@environment).to receive(:submit).and_wrap_original do |original, **options, &work|
      unless Thread.current[:g3c_intercept_submission] && !injected
        next original.call(**options, &work)
      end
      injected = true
      @hidden_worker = original.call(**options) do
        waiting.fetch(:entered) << true
        waiting.fetch(:release).pop
        work.call
      end
      raise IOError, "accepted dispatch preparation lost its handle" if lose_handle
      allow(@hidden_worker).to receive(:on_complete).and_raise(IOError, "dispatch completion registration failed")
      @hidden_worker
    end
  end

  def expect_original_work_only
    expect(@calls.size).to eq(1)
    expect(@effects).to eq((@kind == :provider) ? ["one"] : [])
  end

  def reconcile
    result_of(@agent.reconcile_dispatch_async(recovery: @recovery))
  end

  def retry_save
    result_of(@agent.retry_dispatch_async(recovery: @recovery))
  end

  def expect_retained(receipt, outcome:)
    expect(receipt.outcome).to eq(outcome)
    expect(receipt.application_state).to eq(:pending)
    expect(receipt.continuation_state).to eq(:pending)
    expect(receipt.resolved?).to be(false)
    expect(@agent.pending_dispatch_recovery(execution_id: @execution_id)).to equal(@recovery)
    expect(@registry.agent_execution_admitted?(@agent.agent_id)).to be(true)
    expect_original_work_only
  end

  def expect_resumed(receipt)
    expect(receipt.outcome).to eq(:confirmed_post)
    expect(receipt.application_state).to eq(:applied)
    expect(receipt.continuation_state).to eq(:resumed)
    expect(receipt.resolved?).to be(true)
    expect(receipt.physical_complete?).to be(true)
    expect(receipt.execution_task).to respond_to(:wait_result)
    expect(@agent.pending_dispatch_recovery(execution_id: @execution_id)).to be_nil
    expect { result_of(@original) }.to raise_error { |error| expect(error).to equal(@original_error) }
  end

  def expect_completed(receipt)
    expect_resumed(receipt)
    value = result_of(receipt.execution_task)
    expect(value.fetch(:output)).to eq("recovered answer")
    expect(value.fetch(:execution_id)).to eq(@execution_id)
    expect(@calls.size).to eq(2)
    expect(@effects).to eq(["one"])
    value
  end

  after do
    @gates&.each { |waiting| 4.times { waiting.fetch(:release) << true } }
    @runtime&.shutdown(timeout: 0.03, cancel_grace: 0.03)
  end

  %i[provider tool].each do |kind|
    it "preserves ordinary successful #{kind} preparation without a recovery reference" do
      setup_dispatch(kind: kind, mode: :none)
      value = result_of(@agent.invoke_async("lookup one"))
      expect(value.fetch(:output)).to eq("recovered answer")
      expect(@agent.pending_dispatch_recovery(execution_id: value.fetch(:execution_id))).to be_nil
      expect(@calls.size).to eq(2)
      expect(@effects).to eq(["one"])
    end

    it "recovers a committed #{kind} barrier once and never revives the original failed observer" do
      setup_dispatch(kind: kind)
      start_unknown
      hook_count = @hooks.size

      first = reconcile
      answer = expect_completed(first)
      again = reconcile

      expect_resumed(again)
      expect(again.execution_task).not_to equal(first.execution_task)
      expect(result_of(again.execution_task)).to eq(answer)
      expect(@fault[:commits]).to eq(1)
      expect(@calls.size).to eq(2)
      expect(@effects).to eq(["one"])
      expect(@hooks.size).to eq((kind == :provider) ? hook_count : hook_count + 1)
    end

    it "retains confirmed pre-state for #{kind} and retries the saved proposal without rebuilding input" do
      setup_dispatch(kind: kind, mode: :pre)
      start_unknown
      hook_count = @hooks.size
      root_before = @store.agents.load(@agent.agent_id).to_h
      stored_before = @store.executions.load(@execution_id).to_h

      expect_retained(reconcile, outcome: :confirmed_pre)
      expect(@store.agents.load(@agent.agent_id).to_h).to eq(root_before)
      expect(@store.executions.load(@execution_id).to_h).to eq(stored_before)
      expect(@hooks.size).to eq(hook_count)
      expect_completed(retry_save)

      expect(@hooks.size).to eq((kind == :provider) ? hook_count : hook_count + 1)
      expect(@fault[:commits]).to eq(1)
    end

    it "keeps #{kind} recovery usable after unavailable reads without repeating external work" do
      setup_dispatch(kind: kind)
      start_unknown
      allow(@store.coordinator).to receive(:atomic).and_raise(IOError, "authoritative read unavailable")
      expect_retained(reconcile, outcome: :unavailable)
      allow(@store.coordinator).to receive(:atomic).and_call_original
      expect_completed(reconcile)
    end

    it "does not dispatch #{kind} after cancellation while the save outcome was unknown" do
      setup_dispatch(kind: kind)
      start_unknown
      @token.cancel!
      receipt = reconcile
      expect_resumed(receipt)
      expect { result_of(receipt.execution_task) }.to raise_error(Phronomy::CancellationError)
      expect_original_work_only
      expect(@store.executions.load(@execution_id).status).to eq(:cancelled)
    end
  end

  it "retains a third durable state instead of treating its higher revision as commit proof" do
    setup_dispatch(kind: :tool)
    start_unknown
    current = @store.executions.load(@execution_id)
    changed = current.with(metadata: current.metadata.merge("foreign_change" => true))
    @store.executions.save(@execution_id, expected_revision: current.execution_revision, execution: changed)

    expect_retained(reconcile, outcome: :unresolved)
    expect_retained(retry_save, outcome: :unresolved)

    expect(@store.executions.load(@execution_id).metadata.fetch("foreign_change")).to be(true)
    expect(@fault[:commits]).to eq(1)
  end

  it "rejects another incarnation and malformed capabilities before reading persistence" do
    setup_dispatch(kind: :tool)
    start_unknown
    expect(@store.coordinator).not_to receive(:atomic)
    expect { @agent.dup.reconcile_dispatch_async(recovery: @recovery) }.to raise_error(ArgumentError)
    expect { @agent.retry_dispatch(recovery: Object.new) }.to raise_error(ArgumentError)
    expect(@agent.dup.pending_dispatch_recovery(execution_id: @execution_id)).to be_nil
  end

  it "keeps invocation and unload blocked while dispatch responsibility is retained" do
    setup_dispatch(kind: :provider, mode: :pre)
    start_unknown
    expect { result_of(@agent.invoke_async("another invocation")) }.to raise_error(Phronomy::AgentBusyError)
    expect { @agent.unload! }.to raise_error(Phronomy::AgentBusyError)
    expect_retained(reconcile, outcome: :confirmed_pre)
    expect_completed(retry_save)
    expect(@agent.unload!).to be_truthy
  end

  it "coalesces simultaneous reads while cancelling one observer leaves the owned read intact" do
    setup_dispatch(kind: :provider)
    start_unknown
    waiting = gate
    reads = 0
    allow(@store.coordinator).to receive(:atomic).and_wrap_original do |original, *args, &block|
      reads += 1
      if reads == 1
        waiting.fetch(:entered) << true
        waiting.fetch(:release).pop
      end
      original.call(*args, &block)
    end
    first = @agent.reconcile_dispatch_async(recovery: @recovery)
    take(waiting.fetch(:entered))
    second = @agent.reconcile_dispatch_async(recovery: @recovery)
    first.cancel!
    on_owner { true }
    waiting.fetch(:release) << true

    expect_completed(result_of(second))
    expect { result_of(first) }.to raise_error(Phronomy::CancellationError)
  end

  it "keeps business continuation when its returned observer is cancelled" do
    waiting = gate
    setup_dispatch(kind: :provider, final_provider_gate: waiting)
    start_unknown
    first = reconcile
    expect_resumed(first)
    take(waiting.fetch(:entered))
    first.execution_task.cancel!
    expect { result_of(first.execution_task) }.to raise_error(Phronomy::CancellationError)
    second = reconcile
    expect_resumed(second)
    waiting.fetch(:release) << true
    expect_completed(second)
  end

  it "retains failed Runtime responsibility without silently selecting a replacement Runtime" do
    setup_dispatch(kind: :tool)
    start_unknown
    result = @runtime.shutdown(timeout: 0.02, cancel_grace: 0.02)
    expect(result.cleanup_complete?).to be(false)
    expect_retained(reconcile, outcome: :unavailable)
    expect(@agent.pending_dispatch_recovery(execution_id: @execution_id)).to equal(@recovery)
  end
  it "retains a successful preparation when initial Ready delivery is refused" do
    setup_dispatch(kind: :tool, mode: :none)
    allow(@registry).to receive(:post).and_wrap_original do |original, command, **options|
      if command.is_a?(Phronomy::Agent::DispatchRecoveryOperation::Ready) &&
          command.attempt_id.nil? && command.operation.dispatch_kind == :tool
        false
      else
        original.call(command, **options)
      end
    end
    start_unknown
    allow(@registry).to receive(:post).and_call_original
    expect_completed(reconcile)
  end

  it "retains a completed reconciliation when Ready delivery is refused" do
    setup_dispatch(kind: :provider)
    start_unknown
    allow(@registry).to receive(:post).and_wrap_original do |original, command, **options|
      if command.is_a?(Phronomy::Agent::DispatchRecoveryOperation::Ready) && command.attempt_id
        false
      else
        original.call(command, **options)
      end
    end
    expect_retained(reconcile, outcome: :unavailable)
    allow(@registry).to receive(:post).and_call_original
    expect_completed(reconcile)
  end

  it "separates a confirmed Provider save from a later materialization failure" do
    setup_dispatch(kind: :provider)
    start_unknown
    allow_any_instance_of(Phronomy::Agent::RuntimeInput).to receive(:materialize)
      .and_raise(IOError, "captured input cannot be materialized")
    receipt = reconcile
    expect_resumed(receipt)
    expect { result_of(receipt.execution_task) }.to raise_error(IOError, "captured input cannot be materialized")
    expect_original_work_only
    expect(@store.executions.load(@execution_id).status).to eq(:failed)
  end

  it "does not dispatch again after duplicate initial and reconciliation notifications" do
    setup_dispatch(kind: :tool)
    start_unknown
    operation = @recovery.send(:operation)
    answer = expect_completed(reconcile)
    2.times do
      @registry.post(Phronomy::Agent::DispatchRecoveryOperation::Ready.new(operation: operation, attempt_id: nil))
      @registry.post(Phronomy::Agent::DispatchRecoveryOperation::Ready.new(operation: operation, attempt_id: Object.new))
    end
    on_owner { true }
    expect(result_of(reconcile.execution_task)).to eq(answer)
    expect(@calls.size).to eq(2)
    expect(@effects).to eq(["one"])
  end

  it "does not apply dispatch proof to a changed live execution revision" do
    setup_dispatch(kind: :tool)
    start_unknown
    on_owner do
      state = @registry.agent_execution_state(@execution_id)
      @registry.replace_agent_execution(@execution_id,
        execution: state.execution.with(execution_revision: state.execution.execution_revision + 100))
    end
    receipt = reconcile
    expect(receipt.application_state).to eq(:pending)
    expect(receipt.resolved?).to be(false)
    expect(@agent.pending_dispatch_recovery(execution_id: @execution_id)).to equal(@recovery)
    expect_original_work_only
  end

  %i[provider tool].each do |kind|
    it "keeps #{kind} streaming transport but does not reopen the failed event observation" do
      setup_dispatch(kind: kind)
      start_unknown(stream: true)
      expect_completed(reconcile)
      expect(@stream_calls.size).to eq(2)
      expect(@events.count { |event| event.type == :token }).to eq(0)
      expect(@events.count { |event| event.type == :done }).to eq(0)
    end
  end

  it "does not equate failed observation with physical completion of an accepted preparation" do
    setup_dispatch(kind: :tool, mode: :none)
    waiting = gate
    interrupt_preparation_submission(waiting)
    start_unknown
    take(waiting.fetch(:entered))
    receipt = reconcile
    expect_retained(receipt, outcome: :unavailable)
    expect(receipt.physical_complete?).to be(false)
    expect(@original.physical_complete?).to be(false)
    waiting.fetch(:release) << true
    eventually { @hidden_worker.physical_complete? }
    expect_completed(reconcile)
  end

  it "retains ambiguous submission even after a hidden worker has completed" do
    setup_dispatch(kind: :tool, mode: :none)
    waiting = gate
    interrupt_preparation_submission(waiting, lose_handle: true)
    start_unknown
    take(waiting.fetch(:entered))
    receipt = reconcile
    expect_retained(receipt, outcome: :unavailable)
    expect(receipt.physical_complete?).to be(false)
    waiting.fetch(:release) << true
    eventually { @hidden_worker.physical_complete? }
    receipt = reconcile
    expect_retained(receipt, outcome: :unavailable)
    expect(receipt.physical_complete?).to be(false)
    expect(@runtime.shutdown(timeout: 0.02, cancel_grace: 0.02).cleanup_complete?).to be(false)
  end

  it "does not overwrite a newly persisted cancellation with an older complete pre-state proposal" do
    setup_dispatch(kind: :tool, mode: :pre)
    start_unknown
    expect_retained(reconcile, outcome: :confirmed_pre)
    @store.request_cancellation(agent_id: @agent.agent_id, execution_id: @execution_id)
    expect_retained(retry_save, outcome: :unresolved)
    expect(@store.cancellation_requested?(agent_id: @agent.agent_id, execution_id: @execution_id)).to be(true)
    expect_original_work_only
  end

  %i[provider tool].each do |kind|
    it "honors durable cancellation already captured by #{kind} proof without changing the caller token" do
      setup_dispatch(kind: kind)
      @fault[:capture_cancellation] = true
      start_unknown
      expect(@token).not_to be_cancelled
      expect(@store.cancellation_requested?(agent_id: @agent.agent_id, execution_id: @execution_id)).to be(true)
      receipt = reconcile
      expect_resumed(receipt)
      expect { result_of(receipt.execution_task) }.to raise_error(Phronomy::CancellationError)
      expect_original_work_only
      expect(@token).not_to be_cancelled
      expect(@store.executions.load(@execution_id).status).to eq(:cancelled)
    end
  end

  it "does not resume the old streaming listener after initial Ready rejection" do
    setup_dispatch(kind: :provider, mode: :none)
    allow(@registry).to receive(:post).and_wrap_original do |original, command, **options|
      if command.is_a?(Phronomy::Agent::DispatchRecoveryOperation::Ready) &&
          command.attempt_id.nil? && command.operation.dispatch_kind == :provider
        false
      else
        original.call(command, **options)
      end
    end
    start_unknown(stream: true)
    allow(@registry).to receive(:post).and_call_original
    expect_completed(reconcile)
    expect(@stream_calls.size).to eq(2)
    expect(@events.count { |event| event.type == :token }).to eq(0)
    expect(@events.count { |event| event.type == :done }).to eq(0)
  end

  [[:provider, :cancellation], [:provider, :materialization], [:tool, :cancellation]].each do |kind, failure|
    it "can redeliver a positively refused #{kind} #{failure} event without dispatching external work" do
      setup_dispatch(kind: kind)
      start_unknown
      if failure == :cancellation
        @token.cancel!
      else
        allow_any_instance_of(Phronomy::Agent::RuntimeInput).to receive(:materialize)
          .and_raise(IOError, "captured input cannot be materialized")
      end
      sink = @recovery.send(:operation).invocation.event_sink
      refused = false
      failure_event = (kind == :provider) ? :llm_setup_failed : :tool_setup_failed
      allow(sink).to receive(:post).and_wrap_original do |original, event, *args, **options|
        if event == failure_event && !refused
          refused = true
          false
        else
          original.call(event, *args, **options)
        end
      end
      first = reconcile
      expect(first.outcome).to eq(:confirmed_post)
      expect(first.application_state).to eq(:applied)
      expect(first.continuation_state).to eq(:pending)
      expect(first.resolved?).to be(false)
      expect_original_work_only
      second = reconcile
      expect_resumed(second)
      expected_error = (failure == :cancellation) ? Phronomy::CancellationError : IOError
      expect { result_of(second.execution_task) }.to raise_error(expected_error)
      expect_original_work_only
    end
  end
  it "does not restore dispatch authority when an admitted external call raises at the handoff boundary" do
    waiting = gate
    setup_dispatch(kind: :provider, final_provider_gate: waiting)
    start_unknown
    dispatches = 0
    allow(Phronomy::Agent::InvocationActions).to receive(:start_prepared_provider_call)
      .and_wrap_original do |original, **options|
      dispatches += 1
      original.call(**options)
      raise IOError, "external dispatch admitted but its handoff reply was lost"
    end
    first = reconcile
    take(waiting.fetch(:entered))
    expect(first.outcome).to eq(:confirmed_post)
    expect(first.application_state).to eq(:applied)
    expect(first.continuation_state).to eq(:pending)
    second = reconcile
    expect(second.continuation_state).to eq(:pending)
    expect(second.resolved?).to be(false)
    expect(dispatches).to eq(1)
    expect(@calls.size).to eq(2)
    expect(@effects).to eq(["one"])
    waiting.fetch(:release) << true
    eventually { @store.executions.load(@execution_id).status == :completed }
    final = reconcile
    expect_completed(final)
    expect(dispatches).to eq(1)
  end
  it "redelivers a refused Tool prepared notification without starting admitted children again" do
    setup_dispatch(kind: :tool)
    start_unknown
    sink = @recovery.send(:operation).invocation.event_sink
    refused = false
    allow(sink).to receive(:post).and_wrap_original do |original, event, *args, **options|
      if event == :tool_dispatch_prepared && !refused
        refused = true
        false
      else
        original.call(event, *args, **options)
      end
    end
    dispatches = 0
    allow(Phronomy::Agent::InvocationActions).to receive(:start_prepared_tool_dispatch)
      .and_wrap_original do |original, **options|
      dispatches += 1
      original.call(**options)
    end
    first = reconcile
    expect(first.outcome).to eq(:confirmed_post)
    expect(first.application_state).to eq(:applied)
    expect(first.continuation_state).to eq(:pending)
    eventually { @effects == ["one"] }
    expect(dispatches).to eq(1)
    expect_completed(reconcile)
    expect(dispatches).to eq(1)
  end

  it "redelivers a refused Provider setup failure without retrying input setup or dispatch" do
    setup_dispatch(kind: :provider)
    start_unknown
    setups = 0
    allow(@agent).to receive(:build_llm_request) do
      setups += 1
      raise IOError, "Provider request setup failed after confirmed barrier"
    end
    sink = @recovery.send(:operation).invocation.event_sink
    refused = false
    allow(sink).to receive(:post).and_wrap_original do |original, event, *args, **options|
      if event == :llm_setup_failed && !refused
        refused = true
        false
      else
        original.call(event, *args, **options)
      end
    end
    first = reconcile
    expect(first.outcome).to eq(:confirmed_post)
    expect(first.application_state).to eq(:applied)
    expect(first.continuation_state).to eq(:pending)
    expect_original_work_only
    second = reconcile
    expect_resumed(second)
    expect { result_of(second.execution_task) }.to raise_error(IOError, "Provider request setup failed after confirmed barrier")
    expect(setups).to eq(1)
    expect_original_work_only
  end
  it "accepts later matching FSM progress after a lost dispatch handoff without blocking the next Tool cycle" do
    waiting = gate
    setup_dispatch(kind: :provider, final_provider_gate: waiting)
    start_unknown
    adapter = Phronomy.configuration.llm_adapter
    allow(adapter).to receive(:perform_complete).and_wrap_original do |original, *args, **options|
      response = original.call(*args, **options)
      if @calls.size == 2
        Phronomy::LLMAdapter::Response.new(finish_reason: :tool_calls,
          tool_calls: [Phronomy::Tool::CallRequest.new(id: "lookup-2",
            name: "recovered_dispatch_lookup", arguments: {item: "two"})])
      else
        response
      end
    end
    dispatches = 0
    allow(Phronomy::Agent::InvocationActions).to receive(:start_prepared_provider_call)
      .and_wrap_original do |original, **options|
      dispatches += 1
      value = original.call(**options)
      raise IOError, "second Provider call admitted but handoff reply lost" if dispatches == 1
      value
    end
    first = reconcile
    take(waiting.fetch(:entered))
    expect(first.continuation_state).to eq(:pending)
    expect(dispatches).to eq(1)
    waiting.fetch(:release) << true
    take(waiting.fetch(:entered))
    expect(@effects).to eq(["one", "two"])
    expect(@calls.size).to eq(3)
    expect(dispatches).to eq(2)
    receipt = reconcile
    expect_resumed(receipt)
    waiting.fetch(:release) << true
    answer = result_of(receipt.execution_task)
    expect(answer.fetch(:output)).to eq("recovered answer")
    expect(answer.fetch(:execution_id)).to eq(@execution_id)
    expect(@effects).to eq(["one", "two"])
    expect(@calls.size).to eq(3)
    expect(dispatches).to eq(2)
  end
  [[:provider, :failure_event], [:tool, :failure_event], [:tool, :initial_ready]].each do |kind, refusal|
    it "recovers an unprepared #{kind} failure after #{refusal} refusal without rerunning preparation" do
      setup_dispatch(kind: kind, mode: :none)
      setup_error = IOError.new("#{kind} preparation failed before its dispatch barrier")
      preparation_failures = 0
      if kind == :provider
        @agent.before_llm_input = lambda do |context|
          @hooks << context.call_sequence
          if context.call_sequence == 2
            preparation_failures += 1
            raise setup_error
          end
          nil
        end
      else
        allow(Phronomy::Agent::RuntimeRecordEncoder).to receive(:encode)
          .and_wrap_original do |original, *args, **options|
          if @calls.size == 1 && @effects.empty? && preparation_failures.zero?
            preparation_failures += 1
            raise setup_error
          end
          original.call(*args, **options)
        end
      end
      refused = false
      if refusal == :failure_event
        failure_event = (kind == :provider) ? :llm_setup_failed : :tool_setup_failed
        allow_any_instance_of(Phronomy::FSMSession::EventSink).to receive(:post)
          .and_wrap_original do |original, event, *args|
          if event == failure_event && !refused
            refused = true
            false
          else
            original.call(event, *args)
          end
        end
      else
        allow(@registry).to receive(:post).and_wrap_original do |original, command, **options|
          if command.is_a?(Phronomy::Agent::DispatchRecoveryOperation::Ready) &&
              command.attempt_id.nil? && command.operation.dispatch_kind == kind && !refused
            refused = true
            false
          else
            original.call(command, **options)
          end
        end
      end
      start_unknown
      expect(refused).to be(true)
      expect(@fault[:commits]).to eq(0)
      receipt = reconcile
      expect(receipt.outcome).to eq(:not_prepared)
      expect(receipt.revision).to be_nil
      expect(receipt.application_state).to eq(:applied)
      expect(receipt.continuation_state).to eq(:stopped)
      expect(receipt.physical_complete?).to be(true)
      expect(receipt.resolved?).to be(true)
      expect { result_of(receipt.execution_task) }.to raise_error { |error| expect(error).to equal(setup_error) }
      expect(@agent.pending_dispatch_recovery(execution_id: @execution_id)).to be_nil
      expect(@store.executions.load(@execution_id).status).to eq(:failed)
      again = retry_save
      expect(again.outcome).to eq(:not_prepared)
      expect(again.continuation_state).to eq(:stopped)
      expect { result_of(again.execution_task) }.to raise_error { |error| expect(error).to equal(setup_error) }
      expect(preparation_failures).to eq(1)
      expect(@hooks).to eq((kind == :provider) ? [1, 2] : [1])
      expect_original_work_only
    end
  end
end
