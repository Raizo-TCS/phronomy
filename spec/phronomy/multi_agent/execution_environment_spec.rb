# frozen_string_literal: true

require "spec_helper"
require "open3"

RSpec.describe "MultiAgent execution connection" do
  let(:port) { Phronomy::MultiAgent::ExecutionEnvironment }
  let(:stores) { Phronomy::PersistenceComposition.in_memory }
  let(:admissions) { Phronomy::MultiAgent::AdmissionRegistry.new }
  let(:ownership) { Phronomy::MultiAgent::TeamOwnershipRegistry.new }
  let(:environment) do
    instance_double(Phronomy::MultiAgent::ExecutionEnvironment,
      admissions: admissions, ownership: ownership, existing_ownership: ownership, current?: true)
  end
  let(:worker) do
    Class.new(Phronomy::Agent::Base) { agent_definition id: "environment-worker", version: 1 }
  end
  let(:team_class) do
    agent_class = worker
    Class.new(Phronomy::MultiAgent::TeamCoordinator) do
      team_definition id: "environment-team", version: 1
      pool size: 1, agent: agent_class
    end
  end
  let(:main_agent) { double("main Agent", agent_id: "main", persistence: stores.agent) }

  before { port.install_provider(-> { environment }) }
  after { port.install_provider(-> { Phronomy::MultiAgent::EngineEnvironment.new }) }

  def build_runner
    Phronomy::MultiAgent::HandoffRunner.new(main_agent: main_agent, persistence: stores.multi_agent)
  end

  it "loads and uses the domain registries without Engine or a composition provider" do
    source = <<~RUBY
      require "phronomy/multi_agent/execution_environment"
      require "phronomy/multi_agent/admission_registry"
      require "phronomy/multi_agent/team_ownership_registry"
      admission = Phronomy::MultiAgent::AdmissionRegistry.new
      owner = Object.new
      admission.admit!(owner)
      admission.begin_draining
      abort if admission.wait_until_idle(Process.clock_gettime(Process::CLOCK_MONOTONIC))
      admission.release!(owner)
      abort unless admission.wait_until_idle(Process.clock_gettime(Process::CLOCK_MONOTONIC))
      ownership = Phronomy::MultiAgent::TeamOwnershipRegistry.new
      abort unless ownership.fetch("team", klass: Object, create: true, persistence: nil) { owner }.equal?(owner)
      ownership.begin_draining
      abort unless ownership.wait_until_idle(Process.clock_gettime(Process::CLOCK_MONOTONIC))
      ownership.after_runtime_shutdown
      abort unless ownership.get("team", klass: Object).nil?
      abort if defined?(Phronomy::Runtime) || defined?(Phronomy::EngineEnvironment)
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", source)
    expect(status.success?).to be(true), output
  end

  it "rejects invalid or missing composition" do
    expect { port.install_provider(Object.new) }.to raise_error(ArgumentError, /callable/)
    port.install_provider(-> {})
    expect { port.current }.to raise_error(Phronomy::ConfigurationError, /not been configured/)
  end

  it "preserves Team identity and store validation using only the domain connection" do
    expect(Phronomy::Runtime).not_to receive(:instance)
    team = team_class.create(team_id: "owned", persistence: stores.multi_agent)
    expect(team_class.get("owned")).to equal(team)
    expect(team_class.load("owned", persistence: stores.multi_agent)).to equal(team)
    expect { team_class.create(team_id: "owned", persistence: stores.multi_agent) }
      .to raise_error(Phronomy::Persistence::StateConflictError)
    expect { team_class.load("owned", persistence: Phronomy::PersistenceComposition.in_memory.multi_agent) }
      .to raise_error(Phronomy::ConfigurationError, /mismatch/)
  end

  it "keeps Team lookup from acquiring a registry" do
    allow(environment).to receive(:existing_ownership).and_return(nil)
    expect(environment).not_to receive(:ownership)
    expect(environment).not_to receive(:admissions)
    expect(team_class.get("absent")).to be_nil
  end

  it "rejects stale Team operations before durable admission or cancellation" do
    team = team_class.create(persistence: stores.multi_agent)
    allow(environment).to receive(:current?).and_return(false)
    expect(admissions).not_to receive(:admit!)
    expect(stores.multi_agent).not_to receive(:transaction)
    expect { team.invoke("work") }.to raise_error(Phronomy::RuntimeShutdownError, /previous Runtime/)
    expect { team.resume("run") }.to raise_error(Phronomy::RuntimeShutdownError)
    expect { team.cancel("run") }.to raise_error(Phronomy::RuntimeShutdownError)
    expect(team.executions).to be_empty
  end

  it "retains Team admission ownership when the provider changes" do
    team = team_class.create(persistence: stores.multi_agent)
    port.install_provider(-> { raise "must use originating connection" })
    admissions.admit!(team)
    expect { team.invoke("work") }.to raise_error(Phronomy::HandoffError)
    expect(admissions.idle?).to be(false)
  ensure
    admissions.release!(team)
  end

  it "delivers Team cancellation through the original connection" do
    team = team_class.create(persistence: stores.multi_agent)
    external = Phronomy::Concurrency::CancellationToken.new
    queued = []
    expect(environment).to receive(:submit).with(on_full: :raise).once { |&work| queued << work }
    allow(team).to receive(:run_child) do |_run, _child, _klass, _input, _label, _config, token|
      port.install_provider(-> { raise "must not redirect cancellation" })
      external.cancel!
      expect(token).not_to be_cancelled
      queued.fetch(0).call
      expect(token).to be_cancelled
      raise Phronomy::CancellationError, "cancelled child"
    end
    expect { team.invoke("work", config: {cancellation_token: external}) }.to raise_error(Phronomy::CancellationError)
    run = team.executions.first
    expect(run.status).to eq("cancelled")
    expect(run.metadata.fetch("cancel_requested")).to be(true)
    expect(admissions.idle?).to be(true)
  end

  it "removes the external cancellation callback when a Team call leaves" do
    team = team_class.create(persistence: stores.multi_agent)
    external = Phronomy::Concurrency::CancellationToken.new
    allow(team).to receive(:run_child).and_raise(IOError, "child unavailable")
    expect { team.invoke("work", config: {cancellation_token: external}) }.to raise_error(IOError)
    expect(environment).not_to receive(:submit)
    external.cancel!
    expect(admissions.idle?).to be(true)
  end

  it "releases Handoff admission on failure without selecting a concrete Runtime" do
    expect(Phronomy::Runtime).not_to receive(:instance)
    runner = build_runner
    allow(runner).to receive(:load_state).and_raise(IOError, "read unavailable")
    port.install_provider(-> { raise "must use originating connection" })
    2.times { expect { runner.invoke("work") }.to raise_error(IOError, "read unavailable") }
    expect(admissions.idle?).to be(true)
  end

  it "rejects duplicate Handoff calls across wrappers for the same main Agent" do
    first = build_runner
    second = build_runner
    allow(first).to receive(:load_state) do
      expect { second.invoke("overlap") }.to raise_error(Phronomy::HandoffError)
      expect(admissions.idle?).to be(false)
      raise IOError, "first stops"
    end
    expect { first.invoke("work") }.to raise_error(IOError, "first stops")
    expect(admissions.idle?).to be(true)
  end

  it "rejects stale Handoff invocation before taking admission" do
    runner = build_runner
    allow(environment).to receive(:current?).and_return(false)
    expect(admissions).not_to receive(:admit!)
    expect { runner.invoke("work") }.to raise_error(Phronomy::RuntimeShutdownError, /previous Runtime/)
  end
end
