# frozen_string_literal: true

require "spec_helper"
require "timeout"
require_relative "../../fixtures/handoff_initial_terminal/offline_fixture"

RSpec.describe "Handoff initial terminal finalization through the actual Runtime" do
  App = HandoffTerminalApplication

  before do
    @counts = {}
    @gates = []
  end

  after do
    @gates.each { |gate| gate << true }
    App::IntakeAgent.context_policy(Phronomy::Context::DefaultPolicy.instance)
    App::ReviewAgent.context_policy(Phronomy::Context::DefaultPolicy.instance)
    Phronomy.reset_configuration!
  end

  def open_case(responsibility: "reject case-42")
    @session = App.open_session(handoff: true)
    @source, @target, @runner, @stores = @session.fetch_values(:source, :target, :runner, :stores)
    @session.fetch(:agents).each_value do |agent|
      counts = @counts[agent.agent_id] = {filter: 0, hook: 0, policy: 0}
      allow(agent).to receive(:run_input_filters!).and_wrap_original do |original, input|
        counts[:filter] += 1
        original.call(input)
      end
      allow(agent).to receive(:run_before_llm_input_hooks).and_wrap_original do |original, **options|
        counts[:hook] += 1
        original.call(**options)
      end
      policy = Class.new(Phronomy::Context::ContextPolicy) do
        define_method(:call) do |input|
          counts[:policy] += 1
          Phronomy::Context::DefaultPolicy.instance.call(input)
        end
      end.new
      agent.class.context_policy(policy)
    end
    binding = Phronomy::MultiAgent::HandoffCapabilityFactory.build(@session.fetch(:edge))
    @adapter = App::OfflineFixture::Adapter.new(tool_name: binding.tool_name, responsibility: responsibility)
    Phronomy.configure { |configuration| configuration.llm_adapter = @adapter }
    @session
  end

  def start = App.run_example("case-42", session: @session)
  def route = @stores.multi_agent.handoff_states.load(@source.agent_id)
  def target_execution = @target.persistence.executions.list(@target.agent_id).fetch(0)

  def expect_no_replay
    expect(@adapter.requests.size).to eq(1)
    expect(@counts.fetch(@source.agent_id)).to eq(filter: 1, hook: 1, policy: 1)
    expect(@counts.fetch(@target.agent_id)).to eq(filter: 1, hook: 0, policy: 0)
    expect(@source.persistence.executions.list(@source.agent_id).size).to eq(1)
    expect(@target.persistence.executions.list(@target.agent_id).size).to eq(1)
  end

  # Fault the outer transaction, so post means committed and pre means rolled
  # back. A raise inside save_routing alone cannot simulate a lost commit reply.
  def finalization_fault(mode:, read_unavailable: false)
    @parent_fault = {armed: true, writes: 0, unavailable: read_unavailable}
    allow_any_instance_of(Phronomy::MultiAgent::HandoffTerminalFinalization)
      .to receive(:commit).and_wrap_original do |original, *args|
        previous = Thread.current[:handoff_terminal_save]
        Thread.current[:handoff_terminal_save] = true
        original.call(*args)
      ensure
        Thread.current[:handoff_terminal_save] = previous
      end
    allow_any_instance_of(Phronomy::MultiAgent::HandoffTerminalFinalization)
      .to receive(:reconcile_save).and_wrap_original do |original, *args|
        previous = Thread.current[:handoff_terminal_read]
        Thread.current[:handoff_terminal_read] = true
        original.call(*args)
      ensure
        Thread.current[:handoff_terminal_read] = previous
      end
    allow(@stores.agent.coordinator).to receive(:atomic).and_wrap_original do |original, *args, &transaction|
      if Thread.current[:handoff_terminal_read] && @parent_fault[:unavailable]
        raise IOError, "Parent finalization observation unavailable"
      end
      unless Thread.current[:handoff_terminal_save] && @parent_fault[:armed]
        next original.call(*args, &transaction)
      end
      @parent_fault[:armed] = false
      @parent_fault[:writes] += 1
      if mode == :pre
        original.call(*args) do |scope|
          transaction.call(scope)
          raise IOError, "Parent finalization rolled back; reply lost"
        end
      else
        original.call(*args, &transaction)
        raise IOError, "Parent finalization committed; reply lost"
      end
    end
  end

  def lose_target_failure_reply
    armed = true
    allow_any_instance_of(Phronomy::Agent::InitialPreparation)
      .to receive(:commit_preparation_failure).and_wrap_original do |original, *args, **options|
        previous = Thread.current[:handoff_target_failure]
        Thread.current[:handoff_target_failure] = original.receiver.instance_variable_get(:@agent).equal?(@target)
        original.call(*args, **options)
      ensure
        Thread.current[:handoff_target_failure] = previous
      end
    allow(@stores.agent.coordinator).to receive(:atomic).and_wrap_original do |original, *args, &transaction|
      result = original.call(*args, &transaction)
      if armed && Thread.current[:handoff_target_failure]
        armed = false
        raise IOError, "Target terminal failure committed; reply lost"
      end
      result
    end
  end

  [:before, :after].each do |version|
    it "executes the complete #{version} normal application and explicit cleanup" do
      result = App::OfflineFixture.run(version: version, reject: false)
      work = result.fetch(:work)
      expect(work.fetch(:observation)).to include(state: :observed,
        execution_result: include(output: "case-42 reviewed"))
      expect(result.fetch(:adapter).requests.size).to eq(2)
      expect(App.close_example(work).fetch(:observation)).to eq(state: :closed)
    end
  end

  it "keeps the saved failure while completing parent routing and allowing explicit cleanup" do
    open_case
    work = start
    expect(work.fetch(:observation)).to include(state: :operation_error)
    expect(work.fetch(:observation).fetch(:error).message).to eq("ArgumentError: Review rejected case-42")
    expect(target_execution.status).to eq(:failed)
    expect(route.phase).to eq("stable")
    expect(@runner.result(target_execution.execution_id)).to include(status: :failed)
    expect(@runner.cancel(target_execution.execution_id)).to include(status: :failed)
    expect(App::After.resume(@session, target_execution.execution_id).fetch(:error).message)
      .to eq("ArgumentError: Review rejected case-42")
    expect_no_replay
    expect(App.close_example(work).fetch(:observation)).to eq(state: :closed)
  end

  {cancelled: Phronomy::CancellationError, blocked: Phronomy::FilterBlockError}.each do |status, error_class|
    it "preserves an initial #{status} Target result while settling only its parent routing" do
      open_case
      allow(@target).to receive(:run_input_filters!) do |_input|
        @counts.fetch(@target.agent_id)[:filter] += 1
        raise error_class, "Target preparation #{status}"
      end
      work = start
      expect(work.fetch(:observation)[:state]).to eq(:operation_error)
      expect(target_execution.status).to eq(status)
      expect(route.phase).to eq("stable")
      expect(@runner.cancel(target_execution.execution_id)).to include(status: status)
      expect_no_replay
      expect(App.close_example(work).fetch(:observation)).to eq(state: :closed)
    end
  end

  [:hook, :policy].each do |boundary|
    it "settles a Target #{boundary} failure without replaying successful preparation steps" do
      open_case(responsibility: "review case-42")
      if boundary == :hook
        allow(@target).to receive(:run_before_llm_input_hooks) do |**_options|
          @counts.fetch(@target.agent_id)[:hook] += 1
          raise ArgumentError, "Review hook rejected case-42"
        end
      else
        counter = @counts.fetch(@target.agent_id)
        policy = Class.new(Phronomy::Context::ContextPolicy) do
          define_method(:call) do |_input|
            counter[:policy] += 1
            raise ArgumentError, "Review Policy rejected case-42"
          end
        end.new
        @target.class.context_policy(policy)
      end
      work = start
      expect(work.fetch(:observation)[:state]).to eq(:operation_error)
      expect(target_execution.status).to eq(:failed)
      expect(route.phase).to eq("stable")
      before = @counts.transform_values(&:dup)
      expect(App::After.resume(@session, target_execution.execution_id)[:state]).to eq(:operation_error)
      expect(@counts).to eq(before)
      expect(@counts.fetch(@target.agent_id)).to eq(filter: 1, hook: 1, policy: (boundary == :policy) ? 1 : 0)
      expect(@adapter.requests.size).to eq(1)
      expect(App.close_example(work).fetch(:observation)).to eq(state: :closed)
    end
  end

  it "retains successful history until explicit cleanup and starts a new turn on the active Target" do
    open_case(responsibility: "review case-42")
    first = start.fetch(:observation).fetch(:execution_result)
    expect(route.phase).to eq("stable")
    next_adapter = App::OfflineFixture::Adapter.new(responses: [Phronomy::LLMAdapter::Response.new(content: "next turn", finish_reason: :stop)])
    Phronomy.configure { |configuration| configuration.llm_adapter = next_adapter }
    second = App::After.run(@session, "case-43")
    expect(second).to include(output: "next turn", agent: @target)
    expect(second[:execution_id]).not_to eq(first[:execution_id])
    expect(next_adapter.requests.size).to eq(1)
    expect(@runner.result(first[:execution_id])).to include(output: "case-42 reviewed")
  end

  [:resume, :cancel, :invoke].each do |operation|
    it "retries a confirmed-pre parent save through explicit #{operation} without replaying the failed Target" do
      open_case
      finalization_fault(mode: :pre)
      observation = start.fetch(:observation)
      expect(observation).to include(state: :routing_pending, disposition: :not_committed,
        execution_result: include(status: :failed), read_error: nil)
      expect(observation.fetch(:execution_error).message).to eq("ArgumentError: Review rejected case-42")
      expect(observation.fetch(:error).cause).to equal(observation.fetch(:finalization_error))
      expect(observation[:execution_id]).to eq(@source.persistence.executions.list(@source.agent_id).fetch(0).execution_id)
      expect(route.phase).to eq("target_pending")
      before = route.to_h
      expect(@runner.result(observation.fetch(:execution_id))).to include(status: :failed)
      expect(route.to_h).to eq(before)
      expect { @runner.forget_history! }.to raise_error(Phronomy::AgentBusyError)
      case operation
      when :resume
        expect(App::After.resume(@session, observation.fetch(:execution_id))[:state]).to eq(:operation_error)
      when :cancel
        expect(@runner.cancel(observation.fetch(:execution_id))).to include(status: :failed)
      when :invoke
        expect(App::After.start(@session, "not a new turn")[:state]).to eq(:operation_error)
      end
      expect(route.phase).to eq("stable")
      expect(@parent_fault[:writes]).to eq(1)
      expect_no_replay
    end
  end

  it "adopts an exactly confirmed post-save parent transition and preserves the original failure" do
    open_case
    finalization_fault(mode: :post)
    observation = start.fetch(:observation)
    expect(observation[:state]).to eq(:operation_error)
    expect(observation.fetch(:error).message).to eq("ArgumentError: Review rejected case-42")
    expect(route.phase).to eq("stable")
    expect(@parent_fault[:writes]).to eq(1)
    expect_no_replay
  end

  [:pre, :post].each do |mode|
    it "retains explicit diagnostics after a #{mode} save with an unavailable confirmation read" do
      open_case
      finalization_fault(mode: mode, read_unavailable: true)
      observation = start.fetch(:observation)
      expect(observation).to include(state: :routing_pending, disposition: :unknown,
        execution_result: include(status: :failed))
      expect(observation[:read_error]).to be_a(IOError)
      expect(observation.fetch(:execution_result)).to be_frozen
      @parent_fault[:unavailable] = false
      expect(App::After.resume(@session, observation.fetch(:execution_id))[:state]).to eq(:operation_error)
      expect(route.phase).to eq("stable")
      expect_no_replay
    end
  end

  it "requires explicit D2 recovery before parent finalization despite a readable saved failure" do
    open_case
    lose_target_failure_reply
    work = start
    pending = work.fetch(:observation)
    expect(pending[:state]).to eq(:initial_pending)
    expect(target_execution.status).to eq(:failed)
    expect(route.phase).to eq("target_pending")
    expect(@runner.result(target_execution.execution_id)).to include(status: :failed)
    expect { @runner.cancel(target_execution.execution_id) }.to raise_error(Phronomy::MultiAgent::HandoffFinalizationError) do |error|
      expect(error.disposition).to eq(:not_attempted)
      expect(error.execution_result[:status]).to eq(:failed)
    end
    expect(route.phase).to eq("target_pending")
    expect(App.close_example(work).fetch(:observation)[:state]).to eq(:cleanup_pending)
    waiting = App.begin_initial_recovery(@session, pending)
    settled = App.wait_initial_recovery(waiting, timeout: 8)
    expect(settled[:state]).to eq(:initial_applied)
    expect(App.wait_initial_execution(settled, timeout: 8)).to include(state: :initial_settled,
      execution_result: include(status: :failed))
    expect(App::After.resume(@session, pending.fetch(:execution_id))[:state]).to eq(:operation_error)
    expect(route.phase).to eq("stable")
    expect_no_replay
    expect(App.close_example(work).fetch(:observation)).to eq(state: :closed)
  end

  it "retains a timed-out initial recovery observer and completes that same task before routing progress" do
    open_case
    lose_target_failure_reply
    pending = start.fetch(:observation)
    entered, release = Queue.new, Queue.new
    @gates << release
    gated = false
    allow(@stores.agent.coordinator).to receive(:atomic).and_wrap_original do |original, *args, &transaction|
      unless gated
        gated = true
        entered << true
        release.pop
      end
      original.call(*args, &transaction)
    end
    waiting = App.begin_initial_recovery(@session, pending)
    Timeout.timeout(5) { entered.pop }
    timed_out = App.wait_initial_recovery(waiting, timeout: 0.01)
    expect(timed_out[:state]).to eq(:initial_waiting)
    expect(timed_out[:task]).to equal(waiting[:task])
    expect(timed_out[:wait_error]).to be_a(Phronomy::TimeoutError)
    expect(route.phase).to eq("target_pending")
    release << true
    settled = App.wait_initial_recovery(timed_out, timeout: 8)
    expect(settled[:state]).to eq(:initial_applied)
    expect(settled[:wait_error]).to be_nil
    expect(App.wait_initial_execution(settled, timeout: 8)[:state]).to eq(:initial_settled)
    expect(App::After.resume(@session, pending.fetch(:execution_id))[:state]).to eq(:operation_error)
    expect(route.phase).to eq("stable")
    expect_no_replay
  end

  it "does not repeat history removal when unloading fails after successful cleanup" do
    open_case
    work = start
    forgets = unloads = 0
    allow(@runner).to receive(:forget_history!).and_wrap_original do |original|
      forgets += 1
      original.call
    end
    allow(@source).to receive(:unload!).and_wrap_original do |original|
      unloads += 1
      raise IOError, "Source unload response unavailable" if unloads == 1
      original.call
    end
    waiting = App.close_example(work)
    expect(waiting.fetch(:observation)[:state]).to eq(:cleanup_pending)
    expect(waiting.fetch(:session)).to equal(@session)
    expect(@session[:history_released]).to be(true)
    expect(route).to be_nil
    expect(App.close_example(waiting).fetch(:observation)).to eq(state: :closed)
    expect([forgets, unloads]).to eq([1, 2])
    expect(@adapter.requests.size).to eq(1)
  end

  it "allows explicit forget and a genuinely new main-Agent job after failed Target finalization" do
    open_case
    start
    prior = target_execution.execution_id
    @runner.forget_history!
    adapter = App::OfflineFixture::Adapter.new(responses: [Phronomy::LLMAdapter::Response.new(content: "fresh job", finish_reason: :stop)])
    Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
    result = App::After.run(@session, "case-43")
    expect(result).to include(output: "fresh job", agent: @source)
    expect(result[:execution_id]).not_to eq(prior)
    expect(adapter.requests.size).to eq(1)
  end

  it "rejects changed routing authority after custody observation and permits a later fresh decision" do
    open_case
    revised = nil
    allow_any_instance_of(Phronomy::MultiAgent::HandoffTerminalFinalization)
      .to receive(:assert_released_custody!).and_wrap_original do |original, snapshot|
        original.call(snapshot)
        unless revised
          @stores.multi_agent.transaction do |records, _scope|
            current = records.handoff_states.load_locked(@source.agent_id)
            records.handoff_states.save(@source.agent_id, expected_revision: current.handoff_revision,
              state: current.with(metadata: current.metadata.merge("application_note" => "changed concurrently")))
          end
          revised = route.to_h
        end
      end
    observation = start.fetch(:observation)
    expect(observation).to include(state: :routing_pending, disposition: :not_attempted)
    expect(observation[:finalization_error]).to be_a(Phronomy::Persistence::StateConflictError)
    expect(route.to_h).to eq(revised)
    expect(App::After.resume(@session, observation.fetch(:execution_id))[:state]).to eq(:operation_error)
    expect(route.phase).to eq("stable")
    expect(route.metadata["application_note"]).to eq("changed concurrently")
    expect_no_replay
  end

  def add_second_transfer
    third = App::ReviewAgent.create(persistence: @stores.agent)
    edge = Phronomy::MultiAgent::Handoff.new(source_agent: @target, target_agent: third)
    @session[:agents][third.agent_id] = third
    @runner = @session[:runner] = Phronomy::MultiAgent::HandoffRunner.new(main_agent: @source,
      persistence: @stores.multi_agent, handoffs: [@session.fetch(:edge), edge])
    [third, edge]
  end

  def transfer_response(edge, responsibility, id)
    binding = Phronomy::MultiAgent::HandoffCapabilityFactory.build(edge)
    Phronomy::LLMAdapter::Response.new(finish_reason: :tool_calls, tool_calls: [
      Phronomy::Tool::CallRequest.new(id: id, name: binding.tool_name,
        arguments: {"responsibility" => responsibility})
    ])
  end

  it "releases older Sources before a normal multi-hop Target failure and cleans up that settled chain" do
    open_case(responsibility: "review case-42")
    third, second_edge = add_second_transfer
    @adapter = App::OfflineFixture::Adapter.new(responses: [
      transfer_response(@session.fetch(:edge), "review case-42", "first-transfer"),
      transfer_response(second_edge, "reject case-42", "second-transfer")
    ])
    Phronomy.configure { |configuration| configuration.llm_adapter = @adapter }
    released = nil
    allow(third).to receive(:run_input_filters!).and_wrap_original do |original, input|
      released = [@source, @target].map do |agent|
        !agent.__execution_environment.registry.agent_execution_admitted?(agent.agent_id)
      end
      original.call(input)
    end
    work = start
    expect(work.fetch(:observation)[:state]).to eq(:operation_error)
    expect(released).to eq([true, true])
    expect(route.phase).to eq("stable")
    expect(@source.persistence.executions.list(@source.agent_id).fetch(0).status).to eq(:handed_off)
    expect(@target.persistence.executions.list(@target.agent_id).fetch(0).status).to eq(:handed_off)
    failed = third.persistence.executions.list(third.agent_id).fetch(0)
    expect(failed.status).to eq(:failed)
    expect(@adapter.requests.size).to eq(2)
    expect(App::After.resume(@session, failed.execution_id)[:state]).to eq(:operation_error)
    expect(@adapter.requests.size).to eq(2)
    expect(App.close_example(work).fetch(:observation)).to eq(state: :closed)
    expect { third.unload! }.not_to raise_error
  end

  it "does not let an older terminal chain finalize a newer pending Target" do
    open_case
    third, second_edge = add_second_transfer
    @adapter = App::OfflineFixture::Adapter.new(responses: [
      transfer_response(@session.fetch(:edge), "reject case-42", "old-transfer"),
      transfer_response(second_edge, "reject case-42", "new-transfer")
    ])
    Phronomy.configure { |configuration| configuration.llm_adapter = @adapter }
    start
    old_entry = @source.persistence.executions.list(@source.agent_id).fetch(0).execution_id
    old_target = target_execution.execution_id
    expect(route.phase).to eq("stable")
    finalization_fault(mode: :pre)
    newer = App::After.start(@session, "case-43")
    expect(newer[:state]).to eq(:routing_pending)
    expect(newer[:target_execution_id]).to eq(third.persistence.executions.list(third.agent_id).fetch(0).execution_id)
    pending_route = route.to_h
    expect(App::After.resume(@session, old_entry)[:state]).to eq(:operation_error)
    expect(@runner.cancel(old_entry)).to include(status: :failed, execution_id: old_target)
    expect(route.to_h).to eq(pending_route)
    expect(@adapter.requests.size).to eq(2)
    expect(App::After.resume(@session, newer.fetch(:execution_id))[:state]).to eq(:operation_error)
    expect(route.phase).to eq("stable")
    expect(@adapter.requests.size).to eq(2)
  end

  it "keeps physical Target preparation under custody while concurrent cancel remains responsive" do
    open_case(responsibility: "review case-42")
    entered, release = Queue.new, Queue.new
    @gates << release
    allow(@target).to receive(:run_input_filters!).and_wrap_original do |original, input|
      entered << true
      release.pop
      original.call(input)
    end
    invocation = Thread.new { start }
    Timeout.timeout(5) { entered.pop }
    entry = @source.persistence.executions.list(@source.agent_id).fetch(0).execution_id
    exact_target = route.pending_target_execution_id
    expect(@target.send(:__execution_custody_pending?, exact_target)).to be(true)
    cancelled = Timeout.timeout(5) { @runner.cancel(entry) }
    expect(cancelled).to include(execution_id: exact_target, cancellation_requested: true)
    expect(route.phase).to eq("target_pending")
    expect { @runner.forget_history! }.to raise_error(Phronomy::AgentBusyError)
    expect(@adapter.requests.size).to eq(1)
    release << true
    work = Timeout.timeout(5) { invocation.value }
    observation = work.fetch(:observation)
    if observation[:state] == :initial_pending
      waiting = App.begin_initial_recovery(@session, observation)
      receipt = App.wait_initial_recovery(waiting, timeout: 8)
      details = receipt.fetch(:receipt)
      expect(details).to be_resolved, [details.stage, details.outcome, details.error&.message].inspect
      App.wait_initial_execution(receipt, timeout: 8)
      observation = App::After.resume(@session, observation.fetch(:execution_id))
    end
    expect(observation[:state]).to eq(:operation_error)
    expect(target_execution.status).to eq(:cancelled)
    expect(route.phase).to eq("stable")
    expect(@adapter.requests.size).to eq(1)
    expect(App.close_example(work).fetch(:observation)).to eq(state: :closed)
  ensure
    release << true if release
    invocation&.join(5)
  end

  it "allows concurrent resume and cancel to adopt one exact effective parent transition" do
    open_case
    finalization_fault(mode: :pre)
    entry = start.fetch(:observation).fetch(:execution_id)
    old_revision = route.handoff_revision
    entered, release = Queue.new, Queue.new
    @gates << release << release
    allow_any_instance_of(Phronomy::MultiAgent::HandoffTerminalFinalization)
      .to receive(:assert_released_custody!).and_wrap_original do |original, snapshot|
        original.call(snapshot)
        entered << true
        release.pop
      end
    resumer = Thread.new { App::After.resume(@session, entry) }
    canceller = Thread.new { @runner.cancel(entry) }
    Timeout.timeout(5) { 2.times { entered.pop } }
    2.times { release << true }
    expect(Timeout.timeout(5) { resumer.value }[:state]).to eq(:operation_error)
    expect(Timeout.timeout(5) { canceller.value }).to include(status: :failed)
    expect(route.phase).to eq("stable")
    expect(route.handoff_revision).to eq(old_revision + 1)
    expect_no_replay
  ensure
    2.times { release << true } if release
    resumer&.join(5)
    canceller&.join(5)
  end
end
