# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Feature-owned identity and Runtime shutdown" do
  let(:runtime) { Phronomy::Runtime.instance }
  let(:stores) { Phronomy::PersistenceComposition.in_memory }
  let(:store) { stores.agent }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "ownership-shutdown-agent", version: 1
    end
  end
  let(:team_class) do
    Class.new(Phronomy::MultiAgent::TeamCoordinator) do
      team_definition id: "ownership-shutdown-team", version: 1
    end
  end

  %i[agent team].each do |kind|
    context "with #{kind} ownership" do
      let(:store) { stores.public_send((kind == :team) ? :multi_agent : :agent) }
      let(:owner_class) { (kind == :agent) ? agent_class : team_class }
      let(:environment_class) do
        (kind == :agent) ? Phronomy::Agent::EngineEnvironment : Phronomy::MultiAgent::EngineEnvironment
      end
      let(:environment) { environment_class.new(runtime: runtime) }
      let(:registry) { environment.ownership }
      let(:create_owner) do
        ->(id) { owner_class.create("#{kind}_id": id, persistence: store) }
      end

      it "shares one lazily registered registry per Runtime across concurrent callers" do
        expect(environment.existing_ownership).to be_nil
        start = Queue.new
        threads = Array.new(2) {
          Thread.new {
            start.pop(timeout: 2)
            environment.ownership
          }
        }
        2.times { start << true }
        threads.each { |thread| expect(thread.join(2)).not_to be_nil }
        expect(threads.first.value).to equal(threads.last.value)
        other = Phronomy::Runtime.new
        expect(environment_class.new(runtime: other).ownership).not_to equal(threads.first.value)
      ensure
        threads&.each { |thread| thread.join(2) }
        other&.shutdown
      end

      it "keeps get read-only before first registration and after shutdown" do
        expect(owner_class.get("missing")).to be_nil
        expect(environment.existing_ownership).to be_nil
        expect(runtime.shutdown.cleanup_complete?).to be(true)
        expect(owner_class.get("missing")).to be_nil
        expect(environment.existing_ownership).to be_nil
        expect { create_owner.call("late") }.to raise_error(Phronomy::RuntimeShutdownError)
      end

      it "waits for admitted construction, retains live lookup, and rejects later construction" do
        owner = create_owner.call("live")
        entered = Queue.new
        release = Queue.new
        allow(store).to receive(:transaction).and_wrap_original do |original, &block|
          entered << true
          release.pop(timeout: 3)
          original.call(&block)
        end
        construction = Thread.new { create_owner.call("constructing") }
        expect(entered.pop(timeout: 2)).to be(true)
        waiting = Queue.new
        allow(registry).to receive(:wait_until_idle).and_wrap_original do |original, deadline|
          waiting << true
          original.call(deadline)
        end
        shutdown = Thread.new { runtime.shutdown(timeout: 2) }
        expect(waiting.pop(timeout: 2)).to be(true)
        expect(owner_class.get("live")).to equal(owner)
        expect(environment.ownership).to equal(registry)
        expect { create_owner.call("late") }.to raise_error(Phronomy::RuntimeShutdownError)
        expect { owner_class.load("live", persistence: store) }.to raise_error(Phronomy::RuntimeShutdownError)
        expect(shutdown.join(0.02)).to be_nil
        release << true
        expect(construction.join(2)).not_to be_nil
        expect(construction.value).to be_a(owner_class)
        expect(shutdown.join(2)).not_to be_nil
        expect(shutdown.value.cleanup_complete?).to be(true)
        expect(owner_class.get("live")).to be_nil
        expect(owner_class.get("constructing")).to be_nil
        expect { owner.transcript }.to raise_error(Phronomy::RuntimeShutdownError) if kind == :agent
      ensure
        release << true
        construction&.join(3)
        shutdown&.join(3)
      end

      it "closes an existing registry on EventLoop failure" do
        owner = create_owner.call("live")
        runtime.__event_loop_failed(RuntimeError.new("dispatcher failed"))
        expect(environment.ownership).to equal(registry)
        expect(owner_class.get("live")).to equal(owner)
        expect { create_owner.call("late") }.to raise_error(Phronomy::RuntimeShutdownError)
        expect { owner_class.load("live", persistence: store) }.to raise_error(Phronomy::RuntimeShutdownError)
        expect(runtime.shutdown.cleanup_complete?).to be(true)
        expect(owner_class.get("live")).to be_nil
      end
    end
  end

  it "keeps Agent get validation even when no ownership registry exists" do
    expect { agent_class.get("") }.to raise_error(ArgumentError, /agent_id must not be empty/)
  end

  it "rejects concurrent Agent creation before a second durable write" do
    entered = Queue.new
    release = Queue.new
    expect(store).to receive(:transaction).once.and_wrap_original do |original, &block|
      entered << true
      release.pop(timeout: 3)
      original.call(&block)
    end
    creating = Thread.new { agent_class.create(agent_id: "same", persistence: store) }
    expect(entered.pop(timeout: 2)).to be(true)
    expect { agent_class.create(agent_id: "same", persistence: store) }
      .to raise_error(Phronomy::AgentAlreadyExistsError)
    release << true
    expect(creating.join(2)).not_to be_nil
    expect(agent_class.get("same")).to equal(creating.value)
  ensure
    release << true
    creating&.join(3)
  end

  it "retains Agent ownership and the default Runtime when purge misses the deadline" do
    agent = agent_class.create(agent_id: "purging", persistence: store)
    registry = Phronomy::Agent::EngineEnvironment.new(runtime: runtime).ownership
    token = registry.begin_purge(agent)
    expect(registry).not_to receive(:after_runtime_shutdown)
    expect { Phronomy::Runtime.reset_default!(timeout: 0) }
      .to raise_error(Phronomy::RuntimeShutdownError, /cleanup is incomplete/)
    expect(Phronomy::Runtime.instance).to equal(runtime)
    # An already admitted transition can settle after the gate has closed.
    registry.abort_purge(agent, token)
    expect(agent_class.get("purging")).to equal(agent)
    expect(agent.transcript).to eq([])
    expect { agent.purge! }.to raise_error(Phronomy::RuntimeShutdownError)
  end

  [false, true].each do |initialize_event_loop|
    %i[add_knowledge clear_transcript! clear_knowledge! reset_context! close!].each do |operation|
      it "waits for admitted #{operation} before reset with EventLoop initialized=#{initialize_event_loop}" do
        agent = agent_class.create(agent_id: "updating", persistence: store)
        runtime.event_loop if initialize_event_loop
        registry = Phronomy::Agent::EngineEnvironment.new(runtime: runtime).ownership
        entered = Queue.new
        release = Queue.new
        allow(store).to receive(:transaction).and_wrap_original do |original, &block|
          if Thread.current[:ownership_shutdown_writer]
            entered << true
            release.pop(timeout: 3)
          end
          original.call(&block)
        end
        writer = Thread.new do
          Thread.current[:ownership_shutdown_writer] = true
          (operation == :add_knowledge) ? agent.add_knowledge("accepted update") : agent.public_send(operation)
        end
        expect(entered.pop(timeout: 2)).to be(true)
        waiting = Queue.new
        allow(registry).to receive(:wait_until_idle).and_wrap_original do |original, deadline|
          waiting << true
          original.call(deadline)
        end
        resetting = Thread.new { Phronomy.reset_runtime!(timeout: 2) }
        expect(waiting.pop(timeout: 2)).to be(true)

        expect(agent_class.get("updating")).to equal(agent)
        expect(agent.agent_root.agent_revision).to eq(0)
        expect { agent.add_knowledge("late update") }.to raise_error(Phronomy::RuntimeShutdownError)
        expect(resetting.join(0.02)).to be_nil

        release << true
        expect(writer.join(2)).not_to be_nil
        expect(store.agents.load("updating").agent_revision).to eq(1)
        expect(resetting.join(2)).not_to be_nil
        expect(resetting.value.cleanup_complete?).to be(true)

        replacement = agent_class.load("updating", persistence: store)
        expect(replacement).not_to equal(agent)
        expect(replacement.agent_root.agent_revision).to eq(1)
        expect { replacement.add_knowledge("replacement update") }.not_to raise_error
        expect(store.agents.load("updating").agent_revision).to eq(2)
        expect { agent.add_knowledge("obsolete owner") }.to raise_error(Phronomy::RuntimeShutdownError)
      ensure
        release << true
        writer&.join(3)
        resetting&.join(3)
      end
    end
  end

  it "retains the owner and rejects reset when an admitted update misses the deadline" do
    agent = agent_class.create(agent_id: "updating", persistence: store)
    entered = Queue.new
    release = Queue.new
    allow(store).to receive(:transaction).and_wrap_original do |original, &block|
      if Thread.current[:ownership_shutdown_writer]
        entered << true
        release.pop(timeout: 3)
      end
      original.call(&block)
    end
    writer = Thread.new do
      Thread.current[:ownership_shutdown_writer] = true
      agent.add_knowledge("accepted update")
    end
    expect(entered.pop(timeout: 2)).to be(true)

    expect { Phronomy.reset_runtime!(timeout: 0) }
      .to raise_error(Phronomy::RuntimeShutdownError, /cleanup is incomplete/)
    expect(Phronomy::Runtime.instance).to equal(runtime)
    expect(agent_class.get("updating")).to equal(agent)
    expect(agent.agent_root.agent_revision).to eq(0)
    expect { agent.add_knowledge("late update") }.to raise_error(Phronomy::RuntimeShutdownError)

    release << true
    expect(writer.join(2)).not_to be_nil
    expect(writer.value).to equal(agent)
    expect(agent.agent_root.agent_revision).to eq(1)
    expect(store.agents.load("updating").agent_revision).to eq(1)
    expect { Phronomy.reset_runtime!(timeout: 0) }
      .to raise_error(Phronomy::RuntimeShutdownError, /cleanup is incomplete/)
  ensure
    release << true
    writer&.join(3)
  end

  {
    complete_purge: :__mark_purged!,
    abort_purge: :__restore_live_after_purge_abort!,
    leave_purge_uncertain: :__mark_ownership_recovery_required!
  }.each do |operation, hook|
    it "keeps #{operation} active until the Agent state transition finishes" do
      agent = agent_class.create(agent_id: "purging", persistence: store)
      registry = Phronomy::Agent::EngineEnvironment.new(runtime: runtime).ownership
      token = registry.begin_purge(agent)
      entered = Queue.new
      release = Queue.new
      allow(agent).to receive(hook).and_wrap_original do |original, owner_runtime|
        entered << true
        release.pop(timeout: 3)
        original.call(owner_runtime)
      end
      transition = Thread.new { registry.public_send(operation, agent, token) }
      expect(entered.pop(timeout: 2)).to be(true)
      waiting = Queue.new
      waiter = Thread.new do
        waiting << true
        registry.wait_until_idle(Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2)
      end
      expect(waiting.pop(timeout: 2)).to be(true)
      expect(waiter.join(0.05)).to be_nil
      release << true
      expect(transition.join(2)).not_to be_nil
      expect(transition.value).to be(true)
      expect(waiter.join(2)).not_to be_nil
      expect(waiter.value).to be(true)
      expect(runtime.shutdown.cleanup_complete?).to be(true)
    ensure
      release << true
      transition&.join(3)
      waiter&.join(3)
    end
  end
end
