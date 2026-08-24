# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent same-process live ownership" do
  let(:persistence) { Phronomy::Persistence::InMemory.new }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "same-process-owner-test", version: 1
      model "local-model"
      instructions "Test instruction"
    end
  end

  it "keeps Runtime ownership hooks out of the public Agent API" do
    agent = agent_class.create(agent_id: "agent-private-hooks", persistence: persistence)

    expect(agent.public_methods).not_to include(
      :__prepare_runtime_owner!,
      :__bind_runtime_owner!,
      :__mark_purging!,
      :__restore_live_after_purge_abort!,
      :__mark_ownership_recovery_required!,
      :__mark_purged!,
      :__release_runtime_owner!
    )
  end

  it "preserves subclass initialize keywords when agent_id is omitted" do
    custom_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "custom-initialize-owner-test", version: 1
      model "local-model"
      instructions "Test"

      attr_reader :label

      def initialize(label:)
        @label = label
        super()
      end
    end

    agent = custom_class.new(label: "custom")

    expect(agent.label).to eq("custom")
    expect(agent.agent_id).not_to be_empty
    expect(custom_class.get(agent.agent_id)).to equal(agent)
  end

  it "lets a subclass derive agent_id inside initialize before Base state creation" do
    custom_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "derived-id-owner-test", version: 1
      model "local-model"
      instructions "Test"

      def initialize(account:)
        super(agent_id: "account-#{account}")
      end
    end

    agent = custom_class.new(account: "42")

    expect(agent.agent_id).to eq("account-42")
    expect(custom_class.get("account-42")).to equal(agent)
  end

  it "returns the exact live instance from get and repeated load" do
    agent = agent_class.create(agent_id: "agent-a", persistence: persistence)

    expect(agent_class.get("agent-a")).to equal(agent)
    expect(persistence.agents).not_to receive(:load)
    expect(persistence.journals).not_to receive(:read)
    expect(agent_class.load("agent-a", persistence: persistence)).to equal(agent)
  end

  it "returns nil from get without consulting Persistence" do
    expect(persistence.agents).not_to receive(:load)
    expect(agent_class.get("missing-agent")).to be_nil
  end

  it "keeps load strict when no durable Agent exists" do
    expect {
      agent_class.load("missing-agent", persistence: persistence)
    }.to raise_error(Phronomy::Persistence::NotFoundError)

    expect(agent_class.get("missing-agent")).to be_nil
  end

  it "rejects new/create for an identity that is already live" do
    agent_class.create(agent_id: "agent-a", persistence: persistence)

    expect {
      agent_class.create(agent_id: "agent-a", persistence: persistence)
    }.to raise_error(Phronomy::AgentAlreadyExistsError)

    expect {
      agent_class.new(agent_id: "agent-a", persistence: persistence)
    }.to raise_error(Phronomy::AgentAlreadyExistsError)
  end

  it "rejects new/create when the identity exists durably but is not live" do
    agent_class.create(agent_id: "agent-a", persistence: persistence)
    Phronomy.reset_runtime!

    expect {
      agent_class.create(agent_id: "agent-a", persistence: persistence)
    }.to raise_error(Phronomy::AgentAlreadyExistsError)
  end

  it "hydrates a concurrently requested identity only once" do
    agent_class.create(agent_id: "agent-a", persistence: persistence)
    Phronomy.reset_runtime!

    original_load = persistence.agents.method(:load)
    entered = Queue.new
    release = Queue.new
    count_mutex = Mutex.new
    load_count = 0

    persistence.agents.define_singleton_method(:load) do |agent_id|
      first = count_mutex.synchronize do
        load_count += 1
        load_count == 1
      end
      if first
        entered << true
        release.pop
      end
      original_load.call(agent_id)
    end

    results = Queue.new
    errors = Queue.new
    threads = 2.times.map do
      Thread.new do
        results << agent_class.load("agent-a", persistence: persistence)
      rescue => error
        errors << error
      end
    end

    entered.pop
    # Give the second caller an opportunity to reach the Runtime reservation.
    Thread.pass
    release << true
    threads.each(&:join)

    expect(errors.size).to eq(0)
    loaded = 2.times.map { results.pop }
    expect(loaded[0]).to equal(loaded[1])
    expect(load_count).to eq(1)
  end

  it "rejects resolving a live identity through a different Agent class" do
    other_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "other-owner-test", version: 1
      model "local-model"
      instructions "Other"
    end
    agent_class.create(agent_id: "agent-a", persistence: persistence)

    expect {
      other_class.get("agent-a")
    }.to raise_error(Phronomy::ConfigurationError)

    expect {
      other_class.load("agent-a", persistence: persistence)
    }.to raise_error(Phronomy::ConfigurationError)
  end

  it "rejects load through a different Persistence instance while the Agent is live" do
    agent_class.create(agent_id: "agent-a", persistence: persistence)
    other_persistence = Phronomy::Persistence::InMemory.new

    expect {
      agent_class.load("agent-a", persistence: other_persistence)
    }.to raise_error(Phronomy::ConfigurationError, /different Persistence/)
  end

  it "invalidates old Agent objects when their Runtime shuts down" do
    agent = agent_class.create(agent_id: "agent-a", persistence: persistence)
    Phronomy.reset_runtime!

    expect { agent.transcript }.to raise_error(Phronomy::RuntimeShutdownError)
    expect { agent.add_knowledge("late") }.to raise_error(Phronomy::RuntimeShutdownError)

    loaded = agent_class.load("agent-a", persistence: persistence)
    expect(loaded).not_to equal(agent)
    expect(agent_class.get("agent-a")).to equal(loaded)
  end

  it "keeps an indeterminate create fail-closed instead of materializing a second owner" do
    original_transaction = persistence.method(:transaction)
    fail_after_commit = true
    persistence.define_singleton_method(:transaction) do |&block|
      result = original_transaction.call(&block)
      if fail_after_commit
        fail_after_commit = false
        raise IOError, "connection lost after commit boundary"
      end
      result
    end

    expect {
      agent_class.create(agent_id: "agent-uncertain", persistence: persistence)
    }.to raise_error(IOError, /connection lost/)

    expect { agent_class.get("agent-uncertain") }.to raise_error(
      Phronomy::Error,
      /requires durable recovery\/reconciliation/
    )
    expect {
      agent_class.create(agent_id: "agent-uncertain", persistence: persistence)
    }.to raise_error(Phronomy::Error, /requires durable recovery\/reconciliation/)
  end

  it "turns an indeterminate purge into a stable recovery-required state" do
    agent = agent_class.create(agent_id: "agent-uncertain-purge", persistence: persistence)
    original_transaction = persistence.method(:transaction)
    fail_after_commit = true
    persistence.define_singleton_method(:transaction) do |&block|
      result = original_transaction.call(&block)
      if fail_after_commit
        fail_after_commit = false
        raise IOError, "connection lost after purge commit boundary"
      end
      result
    end

    expect { agent.purge! }.to raise_error(IOError, /connection lost/)
    expect { agent.transcript }.to raise_error(
      Phronomy::Error,
      /requires durable recovery\/reconciliation/
    )
    expect { agent_class.get("agent-uncertain-purge") }.to raise_error(
      Phronomy::Error,
      /requires durable recovery\/reconciliation/
    )
    expect {
      agent_class.load("agent-uncertain-purge", persistence: persistence)
    }.to raise_error(Phronomy::Error, /requires durable recovery\/reconciliation/)
  end

  it "purges explicitly, releases the identity, and never lets the old object affect its replacement" do
    old_agent = agent_class.create(agent_id: "agent-a", persistence: persistence)
    old_agent.add_knowledge("old")

    expect(old_agent.purge!).to be true
    expect(agent_class.get("agent-a")).to be_nil
    expect { old_agent.transcript }.to raise_error(Phronomy::AgentPurgedError)
    expect { old_agent.add_knowledge("late") }.to raise_error(Phronomy::AgentPurgedError)

    replacement = agent_class.create(agent_id: "agent-a", persistence: persistence)
    replacement.add_knowledge("new")
    expect(agent_class.get("agent-a")).to equal(replacement)

    # A stale reference's idempotent second purge must not delete replacement.
    expect(old_agent.purge!).to be true
    expect(agent_class.get("agent-a")).to equal(replacement)
    expect(persistence.agents.load("agent-a").agent_id).to eq("agent-a")
  end

  it "reports not-owned for nil and a purged agent instance" do
    agent = agent_class.create(agent_id: "agent-ownership-check", persistence: persistence)
    runtime = Phronomy::Runtime.instance

    expect(runtime.__agent_owned?(nil)).to be false
    expect(runtime.__agent_owned?(agent)).to be true

    agent.purge!
    expect(runtime.__agent_owned?(agent)).to be false
  end

  it "raises RuntimeShutdownError when begin_purge is called on a non-live agent" do
    agent = agent_class.create(agent_id: "agent-not-live", persistence: persistence)
    agent.purge!

    registry = Phronomy::Runtime.instance.instance_variable_get(:@agent_ownership_registry)
    expect {
      registry.begin_purge(agent)
    }.to raise_error(Phronomy::RuntimeShutdownError)
  end

  it "raises ArgumentError when create is called with an empty agent_id" do
    expect {
      agent_class.create(agent_id: "", persistence: persistence)
    }.to raise_error(ArgumentError, /agent_id must not be empty/)
  end

  it "raises ArgumentError when load_existing internal flag is passed via public create" do
    expect {
      agent_class.new(agent_id: "x", load_existing: true, persistence: persistence)
    }.to raise_error(ArgumentError, /load_existing.*internal hydration/)
  end

  it "raises ArgumentError when shutdown is called with a negative timeout" do
    runtime = Phronomy::Runtime.new
    expect {
      runtime.shutdown(timeout: -1)
    }.to raise_error(ArgumentError, /timeout.*non-negative/)
  end

  it "raises ArgumentError when load is called without persistence" do
    expect {
      agent_class.load("some-id", persistence: nil)
    }.to raise_error(ArgumentError, /persistence is required/)
  end

  it "raises ArgumentError when load is called with an empty agent_id" do
    expect {
      agent_class.load("", persistence: persistence)
    }.to raise_error(ArgumentError, /agent_id must not be empty/)
  end

  it "clears the global instance on reset and sets a new one on next access" do
    original = Phronomy::Runtime.instance
    Phronomy.reset_runtime!
    new_runtime = Phronomy::Runtime.instance

    expect(new_runtime).not_to be(original)
  end

  it "does not clear the global instance when a non-global Runtime shuts down" do
    global = Phronomy::Runtime.instance
    local = Phronomy::Runtime.new

    local.shutdown(timeout: 2)

    expect(Phronomy::Runtime.instance).to be(global)
  end

  it "restores configuration after with_configuration block" do
    original_model = Phronomy.configuration.default_model

    Phronomy.with_configuration do |config|
      config.default_model = "test-model-override"
      expect(Phronomy.configuration.default_model).to eq("test-model-override")
    end

    expect(Phronomy.configuration.default_model).to eq(original_model)
  end
end
