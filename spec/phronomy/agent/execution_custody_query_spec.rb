# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent local execution custody observation" do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "custody-query", version: 1
      model "offline-model"
    end
  end
  let(:agent) { agent_class.create(agent_id: "custody-query-agent") }
  let(:environment) { agent.__execution_environment }
  let(:registry) { environment.registry }
  let(:execution_id) { "custody-query-execution" }

  def query(id = execution_id, target: agent)
    target.send(:__execution_custody_pending?, id)
  end

  def post_action(&action)
    completion = Phronomy::TaskResult.deferred(name: "custody-query-test-action")
    handler = Object.new
    handler.define_singleton_method(:deliver_on_event_loop) do |_command|
      completion.complete(action.call)
    rescue => error
      completion.fail(error)
    end
    registry.post(Struct.new(:coordinator).new(handler), completion: completion)
    completion
  end

  def on_loop(&action)
    post_action(&action).wait_result(timeout: 3)
  end

  it "is an internal semantic hook and rejects malformed identities without creating a Runtime" do
    candidate = agent_class.allocate
    expect(candidate).not_to respond_to(:__execution_custody_pending?)
    expect(Phronomy::Runtime).not_to receive(:instance)
    [nil, "", :execution, 1].each do |id|
      expect { query(id, target: candidate) }.to raise_error(ArgumentError, /nonempty String/)
    end
  end

  it "returns false for a live current incarnation without creating an execution registry or reading Store" do
    agent
    expect(environment.existing_registry).to be_nil
    expect(environment).not_to receive(:registry)
    expect(Phronomy::Runtime).not_to receive(:instance)
    expect(agent.persistence).not_to receive(:transaction)
    expect(agent.persistence).not_to receive(:observe_execution)
    expect(query).to be(false)
    expect(environment.existing_registry).to be_nil
  end

  it "checks availability before taking a missing-registry shortcut" do
    agent
    expect(environment.existing_registry).to be_nil
    expect(environment).to receive(:assert_custody_query_available!)
      .and_raise(Phronomy::RuntimeShutdownError, "observation unavailable")
    expect(environment).not_to receive(:existing_registry)
    expect { query }.to raise_error(Phronomy::RuntimeShutdownError, /unavailable/)
  end

  it "rejects an obsolete Runtime without constructing its replacement" do
    agent
    allow(Phronomy::Runtime).to receive(:__default_if_initialized).and_return(nil)
    expect(Phronomy::Runtime).not_to receive(:instance)
    expect(environment).not_to receive(:existing_registry)
    expect { query }.to raise_error(Phronomy::RuntimeShutdownError, /current running Runtime/)
  end

  it "rejects a foreign Agent incarnation even when its diagnostic identity matches" do
    original = agent
    expect { query(target: original.dup) }.to raise_error(Phronomy::RuntimeShutdownError, /live owner/)
  end

  it "does not treat a constructing incarnation as an available live owner" do
    candidate = agent.dup
    candidate.instance_variable_set(:@_phronomy_runtime_owner_state, :constructing)
    expect { query(target: candidate) }.to raise_error(Phronomy::RuntimeShutdownError, /live incarnation/)
  end

  it "rejects an unloading incarnation instead of treating its registry absence as release" do
    transition, = environment.ownership.reserve_unload(agent)
    expect { query }.to raise_error(Phronomy::AgentBusyError, /unloading/)
  ensure
    environment.ownership.finish_unload(agent, transition, success: false) if transition
  end

  it "rejects EventLoop blocking before starting the observation" do
    expect { on_loop { query } }.to raise_error(Phronomy::EventLoopReentrancyError, /cannot block EventLoop/)
  end

  it "reports unbound admission conservatively and releases only after exact token removal" do
    token = Object.new.freeze
    on_loop { registry.admit_agent_execution(agent.agent_id, owner_token: token) }
    expect(query).to be(true)
    expect(query("different-execution")).to be(true)
    on_loop { registry.release_agent_execution_admission(agent.agent_id, owner_token: token) }
    expect(query).to be(false)
  end

  it "does not conflate a bound different execution with this exact execution" do
    token = Object.new.freeze
    on_loop do
      registry.admit_agent_execution(agent.agent_id, owner_token: token)
      registry.bind_agent_execution_admission(agent.agent_id, owner_token: token, execution_id: "another-execution")
    end
    expect(query).to be(false)
    expect(query("another-execution")).to be(true)
    on_loop { registry.release_agent_execution_admission(agent.agent_id, execution_id: "another-execution") }
  end

  it "observes ordinary initial custody even when no uncertain recovery is exposed" do
    entered, release = Queue.new, Queue.new
    failure = ArgumentError.new("initial input rejected")
    allow(agent).to receive(:run_input_filters!) do
      entered << true
      release.pop(timeout: 5)
      raise failure
    end
    task = agent.invoke_async("input", config: {phronomy_reserved_execution_id: execution_id})
    expect(entered.pop(timeout: 3)).to be(true)
    expect(agent.pending_initial_preparation_recovery).to be_nil
    expect(query).to be(true)
    release << true
    expect { task.wait_result(timeout: 3) }.to raise_error { |error| expect(error).to equal(failure) }
    expect(query).to be(false)
  ensure
    release << true if release
  end

  it "queues behind ordinary terminal delivery before reporting custody release" do
    entered, release, queried = Queue.new, Queue.new, Queue.new
    failure = ArgumentError.new("initial input rejected")
    allow(agent).to receive(:run_input_filters!).and_raise(failure)
    allow(registry).to receive(:resolve_initial_preparation).and_wrap_original do |original, *arguments, **options|
      entered << true
      release.pop(timeout: 5)
      original.call(*arguments, **options)
    end
    allow(registry).to receive(:observe_execution_custody).and_wrap_original do |original, **options|
      original.call(**options).tap { queried << true }
    end
    task = agent.invoke_async("input", config: {phronomy_reserved_execution_id: execution_id})
    expect(entered.pop(timeout: 3)).to be(true)
    expect { task.wait_result(timeout: 3) }.to raise_error { |error| expect(error).to equal(failure) }
    observer = Thread.new { query }
    expect(queried.pop(timeout: 3)).to be(true)
    expect(observer).to be_alive
    expect { environment.ownership.reserve_unload(agent) }.to raise_error(Phronomy::AgentBusyError)
    release << true
    expect(observer.join(3)).to equal(observer)
    expect(observer.value).to be(false)
  ensure
    release << true if release
    observer&.join(3)
  end

  it "does not invoke owner callbacks while inspecting prospective initial identities" do
    owner = double("original initial owner", execution_id: execution_id)
    expect(owner).not_to receive(:pending?)
    expect(owner).not_to receive(:belongs_to?)
    on_loop { registry.instance_variable_get(:@initial_preparations)[agent.agent_id] = owner }
    expect(query).to be(true)
    expect(query("another-execution")).to be(false)
  ensure
    on_loop { registry.instance_variable_get(:@initial_preparations).clear }
  end

  it "keeps each independent exact custody kind visible without relying on a live projection" do
    # These intentionally opaque entries prove the query does not call owners or
    # require another directory entry before acknowledging retained responsibility.
    entries = {:@agent_executions => Object.new, :@terminal_operations => Object.new,
               :@approval_operations => Object.new, :@dispatch_operations => Object.new,
               :@agent_inflight_work => {Object.new => true}, :@agent_deferred_terminals => Object.new,
               :@agent_completion_waiters => [Phronomy::TaskResult.deferred]}
    entries.each do |name, value|
      on_loop { registry.instance_variable_get(name)[execution_id] = value }
      expect(query).to be(true), "missed #{name}"
      expect(query("another-execution")).to be(false)
      on_loop { registry.instance_variable_get(name).delete(execution_id) }
      expect(query).to be(false)
    end
  ensure
    entries&.each_key { |name| on_loop { registry.instance_variable_get(name).delete(execution_id) } }
  end

  it "does not claim absence for an ambiguous foreign same-ID initial owner" do
    foreign = double("foreign initial owner", execution_id: execution_id)
    on_loop { registry.instance_variable_get(:@initial_preparations)["foreign-agent"] = foreign }
    expect(query).to be(true)
  ensure
    on_loop { registry.instance_variable_get(:@initial_preparations).clear }
  end

  it "treats empty physical work and waiter entries as absent without inserting new entries" do
    on_loop do
      registry.instance_variable_get(:@agent_inflight_work)[execution_id] = {}
      registry.instance_variable_get(:@agent_completion_waiters)[execution_id] = []
    end
    expect(query).to be(false)
    expect(query("unindexed-execution")).to be(false)
    on_loop do
      expect(registry.instance_variable_get(:@agent_inflight_work)).not_to have_key("unindexed-execution")
      expect(registry.instance_variable_get(:@agent_completion_waiters)).not_to have_key("unindexed-execution")
    end
  end

  it "raises on query rejection and releases its operation lease" do
    allow(registry).to receive(:post).and_return(false)
    expect { query }.to raise_error(Phronomy::RuntimeShutdownError, /rejected/)
    transition, = environment.ownership.reserve_unload(agent)
    expect(transition).to be_a(Phronomy::Agent::UnloadTransition)
  ensure
    environment.ownership.finish_unload(agent, transition, success: false) if transition
  end

  it "raises when an accepted query loses delivery rather than inventing false" do
    failure = Phronomy::RuntimeShutdownError.new("accepted query delivery stopped")
    allow(registry).to receive(:post) do |_query, completion:|
      completion.fail(failure)
      true
    end
    expect { query }.to raise_error { |error| expect(error).to equal(failure) }
  end

  it "rechecks availability after delivery before exposing a false snapshot" do
    registry
    checks = 0
    allow(environment).to receive(:assert_custody_query_available!).and_wrap_original do |original|
      checks += 1
      raise Phronomy::RuntimeShutdownError, "Runtime changed after observation" if checks == 4
      original.call
    end
    expect { query }.to raise_error(Phronomy::RuntimeShutdownError, /changed after observation/)
  end

  it "fails an accepted serial query during actual Runtime shutdown without deadlocking the lease" do
    entered, release, queued, draining = Queue.new, Queue.new, Queue.new, Queue.new
    blocker = post_action do
      entered << true
      release.pop(timeout: 5)
    end
    expect(entered.pop(timeout: 3)).to be(true)
    allow(registry).to receive(:observe_execution_custody).and_wrap_original do |original, **options|
      original.call(**options).tap { queued << true }
    end
    runtime = Phronomy::Runtime.instance
    allow(runtime.event_loop).to receive(:begin_draining).and_wrap_original do |original|
      original.call.tap { draining << true }
    end
    observer = Thread.new do
      query
    rescue => error
      error
    end
    expect(queued.pop(timeout: 3)).to be(true)
    shutdown = Thread.new { runtime.shutdown(timeout: 3, cancel_grace: 3) }
    expect(draining.pop(timeout: 3)).to be(true)
    release << true
    blocker.wait_result(timeout: 3)
    expect(observer.join(3)).to equal(observer)
    expect(observer.value).to be_a(Phronomy::RuntimeShutdownError)
    expect(shutdown.join(3)).to equal(shutdown)
    expect(shutdown.value).to be_cleanup_complete
  ensure
    release << true if release
    observer&.join(3)
    shutdown&.join(3)
  end
end
