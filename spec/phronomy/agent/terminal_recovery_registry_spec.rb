# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent terminal recovery custody" do
  let(:channel) do
    Class.new do
      attr_reader :messages

      def initialize
        @mutex = Mutex.new
        @messages = []
      end

      def current? = true
      def synchronize(&block) = @mutex.synchronize(&block)
      def admit(_receiver, &block) = synchronize(&block)

      def post(_receiver, message, **_options)
        @messages << message
        true
      end
    end.new
  end
  let(:registry) { Phronomy::Agent::ExecutionRegistry.new(channel: channel) }
  let(:agent) { Struct.new(:agent_id).new("custody-agent") }
  let(:coordinator) { Object.new }
  let(:execution) { Struct.new(:execution_revision, :status).new(3, :active) }
  let(:operation_class) do
    Struct.new(:agent, :coordinator, :execution_id, :fsm_session_id,
      :expected_execution_revision, :recovery, :permitted, :release_count,
      :shutdown_calls, :shutdown_diagnostic, :physical) do
      def agent_id = agent.agent_id
      def recovery_kind = :terminal
      def pending? = release_count.zero?
      def release_permitted? = permitted
      def released = self.release_count += 1

      def retain_original_waiters(waiters)
        @waiters = waiters
      end

      def shutdown(error)
        shutdown_calls << error
        @waiters.each { |task| task.finish_operation! if task.respond_to?(:finish_operation!) } if physical
        shutdown_diagnostic
      end
    end
  end
  let(:operation) do
    operation_class.new(agent: agent, coordinator: coordinator,
      execution_id: "execution-1", fsm_session_id: "session-1",
      expected_execution_revision: 3, recovery: Object.new,
      permitted: false, release_count: 0, shutdown_calls: [], physical: true,
      shutdown_diagnostic: Phronomy::Error.new("retained terminal recovery"))
  end

  def install
    token = Object.new
    registry.admit_agent_execution(agent.agent_id, owner_token: token)
    registry.bind_agent_execution_admission(agent.agent_id,
      owner_token: token, execution_id: operation.execution_id)
    registry.install_agent_execution(execution_id: operation.execution_id,
      agent: agent, coordinator: coordinator, execution: execution,
      runtime_projection: nil, base_manifest: nil, invocation: nil,
      fsm_session_id: "session-1")
  end

  def retained
    install
    registry.retain_terminal_operation(operation)
    registry.mark_agent_execution_admission(agent.agent_id,
      execution_id: operation.execution_id, state: :recovery_required)
  end

  def observer
    Phronomy::Concurrency::PhysicalCompletionTask.deferred.tap do |task|
      task.define_singleton_method(:finish_operation!) { mark_physical_complete! }
      registry.register_agent_completion_waiter(operation.execution_id, task)
    end
  end

  it "retains exact custody and rejects duplicate or different owner references" do
    retained
    expect(registry).not_to be_idle
    expect(registry.owns_terminal_operation?(operation)).to be(true)
    expect(registry.pending_agent_terminal_recovery(operation.execution_id, agent: agent)).to equal(operation.recovery)
    expect(registry.pending_agent_terminal_recovery(operation.execution_id, agent: agent.dup)).to be_nil
    duplicate = operation.dup
    expect(registry.owns_terminal_operation?(duplicate)).to be(false)
    expect { registry.retain_terminal_operation(duplicate) }.to raise_error(Phronomy::Error, /unique matching owner/)
  end

  it "requires the installed coordinator, session and revision at custody acceptance" do
    install
    [{coordinator: Object.new}, {fsm_session_id: "old-session"},
      {expected_execution_revision: 2}, {agent: agent.dup}].each do |change|
      candidate = operation.dup
      change.each { |key, value| candidate[key] = value }
      expect { registry.retain_terminal_operation(candidate) }.to raise_error(Phronomy::Error, /unique matching owner/)
    end
    expect(registry.terminal_operation(operation.execution_id)).to be_nil
  end

  it "keeps actual-terminal and generalized outcome capabilities in separate public lookups" do
    operation.define_singleton_method(:recovery_kind) { :outcome }
    retained
    expect(registry.pending_agent_terminal_recovery(operation.execution_id, agent: agent)).to be_nil
    expect(registry.pending_agent_outcome_recovery(operation.execution_id, agent: agent)).to equal(operation.recovery)
    expect(registry.pending_agent_outcome_recovery(operation.execution_id, agent: agent.dup)).to be_nil
  end

  it "resolves a captured approval wait without releasing its logical execution or admission" do
    operation.define_singleton_method(:recovery_kind) { :outcome }
    retained
    operation.permitted = true
    expect(registry.resolve_outcome_approval_wait(operation)).to be(false)
    registry.replace_agent_execution(operation.execution_id,
      execution: execution.dup.tap { |value| value.status = :suspended })
    operation.permitted = false
    expect(registry.resolve_outcome_approval_wait(operation)).to be(false)
    expect(registry.agent_execution_state(operation.execution_id).fsm_session_id).to eq("session-1")
    operation.permitted = true
    expect(registry.resolve_outcome_approval_wait(operation)).to be(true)
    expect(operation.release_count).to eq(1)
    expect(registry.pending_agent_outcome_recovery(operation.execution_id, agent: agent)).to be_nil
    expect(registry.terminal_operation(operation.execution_id)).to be_nil
    expect(registry.agent_execution_state(operation.execution_id).fsm_session_id).to be_nil
    expect(registry.agent_execution_state(operation.execution_id).execution.status).to eq(:suspended)
    expect(registry.agent_execution_admitted?(agent.agent_id)).to be(true)
    expect(registry.agent_execution_owner(operation.execution_id).agent).to equal(agent)
    expect(registry).to be_idle
  end

  it "forbids ordinary release while terminal custody is retained" do
    retained
    expect(registry.release_terminal_operation(operation)).to be(false)
    expect { registry.release_agent_execution(operation.execution_id) }
      .to raise_error(Phronomy::Error, /terminal operation release/)
    expect(registry.release_agent_execution_admission(agent.agent_id,
      execution_id: operation.execution_id)).to be(false)
    expect(registry.agent_execution_admitted?(agent.agent_id)).to be(true)
    expect(registry.agent_execution_owner(operation.execution_id).agent).to equal(agent)
  end

  it "does not release a changed live session even with a ready operation" do
    retained
    operation.permitted = true
    registry.replace_agent_execution(operation.execution_id, fsm_session_id: "replacement-session")
    expect(registry.owns_terminal_operation?(operation)).to be(false)
    expect(registry.release_terminal_operation(operation)).to be(false)
    expect(registry.agent_execution_admitted?(agent.agent_id)).to be(true)
    expect(operation.release_count).to eq(0)
  end

  it "releases the exact operation and admission only after physical work ends" do
    retained
    work = Phronomy::Concurrency::PhysicalCompletionTask.deferred
    registry.supervise_agent_operation(operation.execution_id, work)
    operation.permitted = true
    expect(registry.release_terminal_operation(operation)).to be(false)
    work.complete(:logical_only)
    expect(registry.release_terminal_operation(operation)).to be(false)
    work.mark_physical_complete!
    registry.deliver(channel.messages.shift)
    expect(registry.release_terminal_operation(operation)).to be(true)
    expect(registry.release_terminal_operation(operation)).to be(false)
    expect(operation.release_count).to eq(1)
    expect(registry).to be_idle
    expect(registry.agent_execution_owner(operation.execution_id)).to be_nil
    expect(registry.agent_execution_admitted?(agent.agent_id)).to be(false)
  end

  it "preserves stopped custody while ending every original observation" do
    retained
    original, additional = observer, observer
    failure = Phronomy::RuntimeShutdownError.new("original receiver stopped")
    registry.shutdown(error: failure)
    expect(operation.shutdown_calls).to eq([failure])
    [original, additional].each do |task|
      expect { task.wait_result }.to raise_error { |error| expect(error).to equal(operation.shutdown_diagnostic) }
      expect(task).to be_physical_complete
    end
    expect(registry).not_to be_idle
    expect(registry.agent_execution_admitted?(agent.agent_id)).to be(true)
    expect(registry.agent_execution_owner(operation.execution_id).agent).to equal(agent)
    expect(registry.pending_agent_terminal_recovery(operation.execution_id, agent: agent)).to equal(operation.recovery)
    expect(registry.owns_terminal_operation?(operation)).to be(true)
  end

  it "fails an ordinary approval observation without completing its domain operation" do
    install
    registry.replace_agent_execution(operation.execution_id,
      execution: execution.dup.tap { |value| value.status = :suspended }, fsm_session_id: nil)
    registry.mark_agent_execution_admission(agent.agent_id,
      execution_id: operation.execution_id, state: :suspended)
    task = observer
    registry.shutdown(error: nil)
    expect { task.wait_result }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    expect(task).not_to be_physical_complete
    expect(registry).to be_idle
    expect(registry.agent_execution_owner(operation.execution_id)).to be_nil
    expect(registry.agent_execution_admitted?(agent.agent_id)).to be(false)
  end

  it "leaves physical acknowledgement with a stopped but still working owner" do
    retained
    task = observer
    operation.physical = false
    registry.shutdown(error: Phronomy::RuntimeShutdownError.new("worker is still running"))
    expect(task).to be_done
    expect(task).not_to be_physical_complete
    expect(registry).not_to be_idle
    expect(registry.terminal_operation(operation.execution_id)).to equal(operation)
  end
end
