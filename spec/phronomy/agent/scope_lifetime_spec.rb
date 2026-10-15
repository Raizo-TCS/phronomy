# frozen_string_literal: true

require "spec_helper"
require "weakref"

RSpec.describe "DX05-E Agent scope and incarnation lifetime" do
  let(:store) { Phronomy::PersistenceComposition.in_memory.agent }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "scope-lifetime", version: 1
      model "local-model"
    end
  end
  let(:agent) { agent_class.create(agent_id: "lifetime", persistence: store) }
  let(:runtime) { Phronomy::Runtime.instance }
  let(:registry) { agent.__execution_environment.registry }

  def on_loop(&action)
    completion = Phronomy::TaskResult.deferred
    handler = Object.new
    handler.define_singleton_method(:deliver_on_event_loop) do |_command|
      completion.complete(action.call)
    rescue => error
      completion.fail(error)
    end
    registry.post(Struct.new(:coordinator).new(handler), completion: completion)
    completion.wait_result(timeout: 3)
  end

  def retain(target = agent)
    value = Phronomy::Agent::Retention.new(agent_id: target.agent_id, owner_key: "opaque:other-domain")
    store.transaction { |tx| tx.retentions.retain(value) }
    value
  end

  def hold_store
    entered, release = Queue.new, Queue.new
    allow(store).to receive(:transaction).and_wrap_original do |original, &block|
      entered << true
      release.pop(timeout: 3)
      original.call(&block)
    end
    [entered, release]
  end

  def successful_chat(&ask)
    response = double("response", role: :assistant, content: "done", tool_calls: nil,
      tokens: Struct.new(:input, :output, :cache_read, :cache_write).new(4, 2, 0, 0), tool_call?: false)
    chat = double("chat")
    %i[with_instructions with_tools with_temperature].each { |method| allow(chat).to receive(method).and_return(chat) }
    %i[cancellation_token= on_tool_call after_message on_tool_result].each { |method| allow(chat).to receive(method) }
    allow(chat).to receive(:messages).and_return([response])
    allow(chat).to receive(:ask) {
      ask&.call
      response
    }
    allow(chat).to receive(:complete).and_return(response)
    allow(RubyLLM).to receive(:chat).and_return(chat)
  end

  it "unloads an idle incarnation without changing durable root, journal, knowledge or history" do
    agent.add_knowledge("remember", metadata: {"source" => "test"})
    before = [agent.agent_root.to_h, agent.transcript, agent.knowledge_snapshot]
    snapshot = agent.agent_root
    expect(agent.unload!).to be(true)
    expect(agent_class.get(agent.agent_id)).to be_nil
    expect(agent.unload!).to be(false)
    listener = ->(_event) {}
    loaded = agent_class.load(agent.agent_id, persistence: store, on_event: listener)
    expect(loaded).not_to equal(agent)
    expect([loaded.agent_root.to_h, loaded.transcript, loaded.knowledge_snapshot]).to eq(before)
    expect(snapshot.to_h).to eq(before.first)
    expect(loaded.event_listener).to equal(listener)
    expect { agent.close! }.to raise_error(Phronomy::AgentUnloadedError) { |e|
      expect([e.code, e.agent_id]).to eq(["agent.unloaded", agent.agent_id])
    }
    expect(loaded.agent_root.to_h).to eq(snapshot.to_h)
  end

  %i[agent_root transcript journal_projection knowledge_snapshot event_listener clear_transcript! clear_knowledge! reset_context! close! purge! before_llm_input].each do |method|
    it "rejects #{method} through an unloaded reference" do
      agent.unload!
      expect { agent.public_send(method) }.to raise_error(Phronomy::AgentUnloadedError)
    end
  end

  it "returns failed handles from every asynchronous old-reference entry" do
    agent.unload!
    tasks = [agent.invoke_async("x"), agent.stream_async("x"), agent.resume_async("execution"),
      agent.cancel_async("execution"), agent.approve_async("execution", approval_request_id: "approval"),
      agent.resolve_async("execution", expected_execution_revision: 0, subject: {}, outcome: :failed),
      agent.start_reserved_async(reservation: nil, input: "x")]
    tasks.each do |task|
      expect(task).to be_a(Phronomy::TaskResult)
      expect { task.wait_result }.to raise_error(Phronomy::AgentUnloadedError)
    end
  end

  it "keeps the durable closed status on reload and preserves purged errors" do
    agent.close!
    root = agent.agent_root
    agent.unload!
    loaded = agent_class.load(agent.agent_id, persistence: store)
    expect(loaded.agent_root.to_h).to eq(root.to_h)
    expect { loaded.invoke("x") }.to raise_error(Phronomy::Error, /closed/)
    loaded.purge!
    expect { loaded.unload! }.to raise_error(Phronomy::AgentPurgedError)
    expect(loaded.purge!).to be(true)
  end

  it "does not remove or interpret durable retention" do
    retained = retain
    expect { agent.unload! }.to raise_error(Phronomy::AgentBusyError)
    expect(agent_class.get(agent.agent_id)).to equal(agent)
    expect(store.transaction { |tx| tx.retentions.list(agent.agent_id) }).to eq([retained])
  end

  it "rejects unload and purge during an admitted synchronous Store mutation" do
    agent
    entered, release = hold_store
    mutation = Thread.new { agent.add_knowledge("pending") }
    expect(entered.pop(timeout: 2)).to be(true)
    expect { agent.unload! }.to raise_error(Phronomy::AgentBusyError)
    expect { agent.purge! }.to raise_error(Phronomy::AgentBusyError)
    release << true
    expect(mutation.join(2)).not_to be_nil
    allow(store).to receive(:transaction).and_call_original
    expect(agent.unload!).to be(true)
  ensure
    release&.push(true)
    mutation&.join(3)
  end

  it "keeps one unload handle; timeout only stops waiting; new operations cannot enter" do
    agent
    entered, release = hold_store
    first = agent.unload_async
    expect(entered.pop(timeout: 2)).to be(true)
    expect(agent.unload_async).to equal(first)
    expect { agent.unload!(timeout: 0.01) }.to raise_error(Phronomy::TimeoutError)
    expect(first).not_to be_done
    expect { agent.add_knowledge("late") }.to raise_error(Phronomy::AgentBusyError)
    expect { agent.invoke_async("late").wait_result }.to raise_error(Phronomy::AgentBusyError)
    expect { agent.purge! }.to raise_error(Phronomy::AgentBusyError)
    release << true
    expect(first.wait_result(timeout: 2)).to be(true)
  ensure
    release&.push(true)
  end

  it "rejects concurrent load immediately; a load after unload gets a fresh owner" do
    agent
    entered, release = hold_store
    unload = agent.unload_async
    entered.pop(timeout: 2)
    expect { agent_class.load(agent.agent_id, persistence: store) }.to raise_error(Phronomy::AgentBusyError)
    allow(store).to receive(:transaction).and_call_original
    release << true
    expect(unload.wait_result(timeout: 2)).to be(true)
    expect(agent_class.load(agent.agent_id, persistence: store)).not_to equal(agent)
  ensure
    release&.push(true)
  end

  it "rolls back a failed read with the exact original error and permits a later retry" do
    agent
    failure = IOError.new("read failed")
    allow(store).to receive(:transaction).and_raise(failure)
    expect { agent.unload! }.to raise_error { |e| expect(e).to equal(failure) }
    expect(agent_class.get(agent.agent_id)).to equal(agent)
    allow(store).to receive(:transaction).and_call_original
    expect(agent.unload!).to be(true)
  end

  it "rolls back initial post rejection without leaking the transition" do
    agent
    allow(registry).to receive(:post).and_return(false)
    expect { agent.unload! }.to raise_error(Phronomy::RuntimeShutdownError)
    expect(agent_class.get(agent.agent_id)).to equal(agent)
    allow(registry).to receive(:post).and_call_original
    expect(agent.unload!).to be(true)
  end

  it "rolls back physical-completion delivery rejection" do
    agent
    calls = 0
    allow(registry).to receive(:post).and_wrap_original do |original, *args, **kwargs|
      calls += 1
      (calls == 2) ? false : original.call(*args, **kwargs)
    end
    expect { agent.unload! }.to raise_error(Phronomy::RuntimeShutdownError)
    expect(agent_class.get(agent.agent_id)).to equal(agent)
  end

  it "rejects synchronous lifecycle calls on EventLoop before Store work" do
    agent
    expect(store).not_to receive(:transaction)
    on_loop do
      expect { agent.unload! }.to raise_error(Phronomy::EventLoopReentrancyError)
      expect { Phronomy::Agent.open_scope {} }.to raise_error(Phronomy::EventLoopReentrancyError)
    end
  end

  it "accepts asynchronous unload on EventLoop" do
    task = on_loop { agent.unload_async }
    expect(task.wait_result(timeout: 2)).to be(true)
  end

  %i[admitting executing suspended resuming cancelling terminalizing recovery_required].each do |phase|
    it "retains the owner for #{phase} execution admission" do
      on_loop do
        registry.admit_agent_execution(agent.agent_id, owner_token: Object.new)
        unless phase == :admitting
          registry.bind_agent_execution_admission(agent.agent_id,
            owner_token: registry.instance_variable_get(:@agent_admissions)[agent.agent_id].owner_token,
            execution_id: "execution")
          registry.mark_agent_execution_admission(agent.agent_id, execution_id: "execution", state: phase)
        end
      end
      expect { agent.unload! }.to raise_error(Phronomy::AgentBusyError)
      expect(agent_class.get(agent.agent_id)).to equal(agent)
    ensure
      on_loop do
        entry = registry.instance_variable_get(:@agent_admissions)[agent.agent_id]
        registry.release_agent_execution_admission(agent.agent_id, owner_token: entry.owner_token) if entry
      end
    end
  end

  it "drains an accepted unload during Runtime shutdown without reviving the owner" do
    agent
    entered, release = hold_store
    unload = agent.unload_async
    entered.pop(timeout: 2)
    draining = Queue.new
    ownership = agent.__execution_environment.ownership
    allow(ownership).to receive(:wait_until_idle).and_wrap_original do |original, deadline|
      draining << true
      original.call(deadline)
    end
    shutdown = Thread.new { runtime.shutdown(timeout: 2) }
    draining.pop(timeout: 2)
    release << true
    expect(unload.wait_result(timeout: 2)).to be(true)
    expect(shutdown.join(2)).not_to be_nil
    expect(shutdown.value.cleanup_complete?).to be(true)
    expect(agent.unload!).to be(false)
    expect { agent.transcript }.to raise_error(Phronomy::AgentUnloadedError)
  ensure
    release&.push(true)
    shutdown&.join(3)
  end

  it "leaves another Agent and the shared Store available" do
    other = agent_class.create(agent_id: "other", persistence: store)
    agent.unload!
    other.add_knowledge("still open")
    expect(agent_class.get(other.agent_id)).to equal(other)
    expect(store.agents.load(agent.agent_id).agent_id).to eq(agent.agent_id)
  end

  it "keeps a cancelled queued invocation admitted until the accepted command is processed" do
    successful_chat
    agent
    entered, release = Queue.new, Queue.new
    handler = Object.new
    handler.define_singleton_method(:deliver_on_event_loop) { |_|
      entered << true
      release.pop(timeout: 3)
    }
    registry.post(Struct.new(:coordinator).new(handler))
    entered.pop(timeout: 2)
    invocation = agent.invoke_async("queued")
    invocation.cancel!
    expect { agent.unload! }.to raise_error(Phronomy::AgentBusyError)
    expect { agent.purge! }.to raise_error(Phronomy::AgentBusyError)
    physically_done = Queue.new
    invocation.on_physical_complete { physically_done << true }
    release << true
    expect(physically_done.pop(timeout: 3)).to be(true)
    expect(agent.unload!).to be(true)
  ensure
    release&.push(true)
  end

  it "retains physical LLM work after handle cancellation without blocking another Agent's unload" do
    entered, release = Queue.new, Queue.new
    successful_chat {
      entered << true
      release.pop(timeout: 3)
    }
    other = agent_class.create(agent_id: "independent", persistence: store)
    invocation = agent.invoke_async("running")
    entered.pop(timeout: 2)
    invocation.cancel!
    expect { agent.unload! }.to raise_error(Phronomy::AgentBusyError)
    expect(other.unload!).to be(true)
    physically_done = Queue.new
    invocation.on_physical_complete { physically_done << true }
    release << true
    expect(physically_done.pop(timeout: 3)).to be(true)
    expect(agent.unload!).to be(true)
  ensure
    release&.push(true)
  end

  it "keeps terminal listener dispatch inside the accepted operation" do
    successful_chat
    observed = Queue.new
    value = agent_class.create(persistence: store, on_event: ->(event) {
      observed << value.unload_async if event.type == :done
    })
    invocation = value.invoke_async("x")
    expect(invocation.wait_result(timeout: 3)[:output]).to eq("done")
    expect { observed.pop(timeout: 2).wait_result }.to raise_error(Phronomy::AgentBusyError)
    expect(value.unload!).to be(true)
  end

  it "cleans up a complete invocation returned from the application block" do
    successful_chat
    result = Phronomy::Agent.open_scope do |scope|
      scope.create(agent_class, persistence: store).invoke_async("x")
    end
    expect(result[:output]).to eq("done")
  end

  it "does not wait for or cancel a child whose handle was cancelled by the parent" do
    entered, release = Queue.new, Queue.new
    successful_chat {
      entered << true
      release.pop(timeout: 3)
    }
    owned = invocation = nil
    cancellation = Phronomy::CancellationError.new("parent ended")
    expect {
      Phronomy::Agent.open_scope do |scope|
        owned = scope.create(agent_class, persistence: store)
        invocation = owned.invoke_async("child")
        entered.pop(timeout: 2)
        invocation.cancel!(cancellation)
        invocation
      end
    }.to raise_error(Phronomy::Agent::ScopeCleanupError) { |error|
      expect(error.primary_error).to equal(cancellation)
      expect(error.cause).to equal(cancellation)
      expect(error.result).to be_nil
      @failed_scope = error.scope
    }
    expect(agent_class.get(owned.agent_id)).to equal(owned)
    physically_done = Queue.new
    invocation.on_physical_complete { physically_done << true }
    release << true
    expect(physically_done.pop(timeout: 3)).to be(true)
    expect(owned.unload!).to be(true)
  ensure
    release&.push(true)
  end

  it "does not retain an unloaded Agent through the registry or completed release handle" do
    reference, task = Thread.new do
      value = agent_class.create(agent_id: "collectible", persistence: store)
      result = value.unload_async
      result.wait_result(timeout: 2)
      [WeakRef.new(value), result]
    end.value
    on_loop { true }
    3.times { GC.start }
    expect(reference.weakref_alive?).to be_falsey
    expect(task.wait_result).to be(true)
  end

  it "owns multiple new Agents and unwraps a returned TaskResult" do
    first = second = nil
    result = Phronomy::Agent.open_scope do |scope|
      first = scope.create(agent_class, persistence: store)
      second = scope.create_async(agent_class, persistence: store).wait_result
      expect(scope.load(agent_class, first.agent_id, persistence: store)).to equal(first)
      expect(scope.load_async(agent_class, first.agent_id, persistence: store).wait_result).to equal(first)
      Phronomy::TaskResult.completed(:answer)
    end
    expect(result).to eq(:answer)
    [first, second].each { |a| expect { a.transcript }.to raise_error(Phronomy::AgentUnloadedError) }
  end

  it "rejects external owners and owners from another scope" do
    agent
    Phronomy::Agent.open_scope do |first|
      owned = first.create(agent_class, persistence: store)
      Phronomy::Agent.open_scope do |second|
        expect { second.load(agent_class, agent.agent_id, persistence: store) }.to raise_error(Phronomy::AgentBusyError)
        expect { second.load(agent_class, owned.agent_id, persistence: store) }.to raise_error(Phronomy::AgentBusyError)
      end
      expect(agent_class.get(owned.agent_id)).to equal(owned)
    end
    expect(agent_class.get(agent.agent_id)).to equal(agent)
  end

  it "rejects rebinding a live listener or changing the Store within the same scope" do
    Phronomy::Agent.open_scope do |scope|
      owned = scope.create(agent_class, persistence: store)
      expect { scope.load(agent_class, owned.agent_id, persistence: store, on_event: ->(_) {}) }.to raise_error(Phronomy::ConfigurationError)
      expect { scope.load(agent_class, owned.agent_id, persistence: Phronomy::PersistenceComposition.in_memory.agent) }.to raise_error(Phronomy::ConfigurationError)
    end
  end

  it "attempts all cleanup and exposes original failures plus the successful result" do
    held = free = nil
    expect {
      Phronomy::Agent.open_scope do |scope|
        held = scope.create(agent_class, persistence: store)
        free = scope.create(agent_class, persistence: store)
        retain(held)
        :completed_work
      end
    }.to raise_error(Phronomy::Agent::ScopeCleanupError) { |error|
      expect(error.code).to eq("agent.scope_cleanup_failed")
      expect(error.result).to eq(:completed_work)
      expect(error.failures.map { |f| f[:agent_id] }).to eq([held.agent_id])
      expect(error.failures.first[:error]).to be_a(Phronomy::AgentBusyError)
    }
    expect(agent_class.get(held.agent_id)).to equal(held)
    expect(agent_class.get(free.agent_id)).to be_nil
  end

  it "preserves the primary exception even when cleanup and diagnostic logging fail" do
    primary = IOError.new("business failure")
    logger = double("broken logger")
    allow(logger).to receive(:warn).and_raise("logger failed")
    allow(Phronomy::RuntimeSettings.current).to receive(:logger).and_return(logger)
    expect {
      Phronomy::Agent.open_scope do |scope|
        retain(scope.create(agent_class, persistence: store))
        raise primary
      end
    }.to raise_error(Phronomy::Agent::ScopeCleanupError) { |error|
      expect(error.primary_error).to equal(primary)
      expect(error.cause).to equal(primary)
      expect(error.failures.length).to eq(1)
    }
  end

  it "rejects new acquisition after the scope has released" do
    saved = nil
    Phronomy::Agent.open_scope { |scope|
      saved = scope
      nil
    }
    expect { saved.create(agent_class, persistence: store) }.to raise_error(Phronomy::Error, /released/)
    expect { saved.create_async(agent_class, persistence: store).wait_result }.to raise_error(Phronomy::Error, /released/)
  end

  it "accepts asynchronous materialization on EventLoop and rejects synchronous calls" do
    Phronomy::Agent.open_scope do |scope|
      task = on_loop do
        expect { scope.create(agent_class, persistence: store) }.to raise_error(Phronomy::EventLoopReentrancyError)
        expect { scope.load(agent_class, agent.agent_id, persistence: store) }.to raise_error(Phronomy::EventLoopReentrancyError)
        scope.create_async(agent_class, persistence: store)
      end
      expect(task.wait_result(timeout: 2)).to be_a(agent_class)
      nil
    end
  end

  it "tracks cancelled asynchronous materialization to physical completion while closing" do
    entered, release = hold_store
    returned = Queue.new
    closing = Thread.new do
      Phronomy::Agent.open_scope do |scope|
        task = scope.create_async(agent_class, agent_id: "late-materialization", persistence: store)
        entered.pop(timeout: 2)
        task.cancel!
        returned << true
        :business_done
      end
    end
    returned.pop(timeout: 2)
    expect(closing.join(0.01)).to be_nil
    allow(store).to receive(:transaction).and_call_original
    release << true
    expect(closing.join(2)).not_to be_nil
    expect(closing.value).to eq(:business_done)
    expect(agent_class.get("late-materialization")).to be_nil
    expect(store.agents.load("late-materialization").agent_id).to eq("late-materialization")
  ensure
    release&.push(true)
    closing&.join(3)
  end

  it "leaves an uncertain create reserved and reports its identity" do
    failure = IOError.new("unknown commit")
    allow(store).to receive(:transaction).and_raise(failure)
    expect {
      Phronomy::Agent.open_scope { |scope| scope.create(agent_class, agent_id: "uncertain", persistence: store) }
    }.to raise_error { |error| expect(error).to equal(failure) }
    expect { agent_class.get("uncertain") }.to raise_error(Phronomy::Error, /uncertain.*recovery/)
    allow(store).to receive(:transaction).and_call_original
    expect { agent_class.create(agent_id: "uncertain", persistence: store) }.to raise_error(Phronomy::Error, /recovery/)
  end
end
