# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "Runtime shutdown participants" do
  let(:runtime) { Phronomy::Runtime.new }

  after { runtime.shutdown(timeout: 0) }

  it "constructs and shuts down Runtime without a Multi-Agent admission definition" do
    source = <<~RUBY
      require "phronomy"
      Phronomy::MultiAgent.send(:remove_const, :AdmissionRegistry)
      runtime = Phronomy::Runtime.new
      abort "cleanup failed" unless runtime.shutdown.cleanup_complete?
      abort "Runtime loaded Multi-Agent admission" if Phronomy::MultiAgent.const_defined?(:AdmissionRegistry, false)
    RUBY
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", source
    )
    expect(status.success?).to be(true), [stdout, stderr].join("\n")
  end

  it "rejects an incomplete shutdown contract at registration" do
    expect {
      runtime.__register_shutdown_participant(key: :invalid, participant: Object.new)
    }.to raise_error(ArgumentError, /begin_draining and wait_until_idle/)
    expect(runtime.shutdown.cleanup_complete?).to be(true)
  end

  it "looks up existing participants without registration or reopening admission" do
    participant = double("participant", begin_draining: nil, wait_until_idle: true)
    expect(runtime.__shutdown_participant(key: :missing)).to be_nil
    runtime.__register_shutdown_participant(key: :owner, participant: participant)
    expect(runtime.__shutdown_participant(key: :owner)).to equal(participant)
    runtime.shutdown
    expect(runtime.__shutdown_participant(key: :owner)).to equal(participant)
    expect(runtime.__shutdown_participant(key: :missing)).to be_nil
    expect { runtime.__register_shutdown_participant(key: :owner, participant: participant) }
      .to raise_error(Phronomy::RuntimeShutdownError)
  end

  it "finalizes once outside the lifecycle lock after EventLoop and workers stop" do
    loop_instance = runtime.event_loop
    pool = runtime.offload
    pool_stopped = false
    allow(pool).to receive(:shutdown).and_wrap_original do |original|
      original.call
      pool_stopped = true
    end
    participant = double("participant", begin_draining: nil, wait_until_idle: true)
    expect(participant).to receive(:after_runtime_shutdown).once do
      expect(runtime.state).to eq(:stopping)
      expect(loop_instance.thread_alive?).to be(false)
      expect(pool_stopped).to be(true)
    end
    runtime.__register_shutdown_participant(key: :owner, participant: participant)
    result = runtime.shutdown
    expect(result.cleanup_complete?).to be(true)
    expect(runtime.shutdown).to equal(result)
  end

  it "does not finalize any participant when one wait misses the deadline" do
    first = double("busy participant", begin_draining: nil, wait_until_idle: false)
    second = double("idle participant", begin_draining: nil, wait_until_idle: true)
    [first, second].each_with_index do |participant, index|
      expect(participant).not_to receive(:after_runtime_shutdown)
      runtime.__register_shutdown_participant(key: index, participant: participant)
    end
    expect(runtime.shutdown(timeout: 0).cleanup_complete?).to be(false)
  end

  it "does not finalize participants when worker shutdown fails" do
    participant = double("participant", begin_draining: nil, wait_until_idle: true)
    expect(participant).not_to receive(:after_runtime_shutdown)
    runtime.__register_shutdown_participant(key: :owner, participant: participant)
    allow(runtime.offload).to receive(:shutdown).and_wrap_original do |original|
      original.call
      raise IOError, "worker shutdown failed"
    end
    result = runtime.shutdown
    expect(result.cleanup_complete?).to be(false)
    expect(result.error.message).to eq("worker shutdown failed")
  end

  it "continues finalization after a hook fails and retains the default Runtime" do
    previous = Phronomy::Runtime.replace_default_for_test(runtime)
    failure = RuntimeError.new("finalization failed")
    first = double("failed participant", begin_draining: nil, wait_until_idle: true)
    expect(first).to receive(:after_runtime_shutdown).ordered.and_raise(failure)
    second = double("healthy participant", begin_draining: nil, wait_until_idle: true)
    expect(second).to receive(:after_runtime_shutdown).ordered
    runtime.__register_shutdown_participant(key: :first, participant: first)
    runtime.__register_shutdown_participant(key: :second, participant: second)
    expect { Phronomy::Runtime.reset_default! }
      .to raise_error(Phronomy::RuntimeShutdownError, /cleanup is incomplete/)
    expect(Phronomy::Runtime.instance).to equal(runtime)
    result = runtime.shutdown
    expect(result.cleanup_complete?).to be(false)
    expect(result.runtime_outcome).to eq(:failed)
    expect(result.error).to equal(failure)
  ensure
    Phronomy::Runtime.restore_default_for_test(previous)
  end

  it "shares one registry per Runtime even when callers register concurrently" do
    start = Queue.new
    threads = Array.new(2) do
      Thread.new do
        start.pop(timeout: 2)
        Phronomy::MultiAgent::AdmissionRegistry.for(runtime)
      end
    end
    2.times { start << true }
    threads.each { |thread| expect(thread.join(2)).not_to be_nil }
    expect(threads.first.value).to equal(threads.last.value)
    other = Phronomy::Runtime.new
    expect(Phronomy::MultiAgent::AdmissionRegistry.for(other)).not_to equal(threads.first.value)
  ensure
    threads&.each { |thread| thread.join(2) }
    other&.shutdown
  end

  it "closes every participant before any wait and uses one deadline for all waits" do
    events = []
    deadlines = []
    %i[first second].each do |key|
      participant = double("shutdown participant")
      allow(participant).to receive(:begin_draining) { events << [:close, key] }
      allow(participant).to receive(:wait_until_idle) do |deadline|
        deadlines << deadline
        events << [:wait, key, runtime.state]
        true
      end
      runtime.__register_shutdown_participant(key: key, participant: participant)
    end
    result = runtime.shutdown(timeout: 1)
    expect(events).to eq([[:close, :first], [:close, :second],
      [:wait, :first, :draining], [:wait, :second, :draining]])
    expect(deadlines.uniq.size).to eq(1)
    expect(result.clean?).to be(true)
  end

  it "rejects a registration racing with shutdown, including reuse of an existing key" do
    closing = Queue.new
    continue_closing = Queue.new
    participant = double("shutdown participant", wait_until_idle: true)
    allow(participant).to receive(:begin_draining) do
      closing << true
      continue_closing.pop(timeout: 2)
    end
    runtime.__register_shutdown_participant(key: :participant, participant: participant)
    shutdown = Thread.new { runtime.shutdown(timeout: 1) }
    expect(closing.pop(timeout: 2)).to be(true)
    registering = Queue.new
    registration = Thread.new do
      registering << true
      begin
        runtime.__register_shutdown_participant(key: :participant, participant: participant)
      rescue Phronomy::RuntimeShutdownError => error
        error
      end
    end
    expect(registering.pop(timeout: 2)).to be(true)
    continue_closing << true
    expect(registration.join(2)).not_to be_nil
    expect(registration.value).to be_a(Phronomy::RuntimeShutdownError)
    expect(shutdown.join(2)).not_to be_nil
    expect(shutdown.value.cleanup_complete?).to be(true)
  ensure
    continue_closing << true
    registration&.join(2)
    shutdown&.join(2)
  end

  it "waits for an admitted call while rejecting later calls through a cached registry" do
    registry = Phronomy::MultiAgent::AdmissionRegistry.for(runtime)
    owner = Object.new
    registry.admit!(owner)
    waiting = Queue.new
    allow(registry).to receive(:wait_until_idle).and_wrap_original do |original, deadline|
      waiting << true
      original.call(deadline)
    end
    shutdown = Thread.new { runtime.shutdown(timeout: 2) }
    expect(waiting.pop(timeout: 2)).to be(true)
    expect(runtime.state).to eq(:draining)
    expect { registry.admit!(Object.new) }.to raise_error(Phronomy::RuntimeShutdownError)
    expect(registry.idle?).to be(false)
    registry.release!(owner)
    expect(shutdown.join(2)).not_to be_nil
    expect(shutdown.value.clean?).to be(true)
  ensure
    registry&.release!(owner)
    shutdown&.join(2)
  end

  it "closes cached admission on EventLoop failure while allowing admitted calls to release" do
    registry = Phronomy::MultiAgent::AdmissionRegistry.for(runtime)
    owner = Object.new
    registry.admit!(owner)
    failure = RuntimeError.new("EventLoop failed")
    runtime.__event_loop_failed(failure)
    expect { registry.admit!(Object.new) }.to raise_error(Phronomy::RuntimeShutdownError)
    expect { Phronomy::MultiAgent::AdmissionRegistry.for(runtime) }.to raise_error(Phronomy::RuntimeShutdownError)
    expect(registry.release!(owner)).to be(true)
    result = runtime.shutdown
    expect(result.error).to equal(failure)
    expect(result.runtime_outcome).to eq(:failed)
    expect(result.cleanup_complete?).to be(true)
  ensure
    registry&.release!(owner)
  end

  it "keeps default Runtime when a participant misses the deadline" do
    previous = Phronomy::Runtime.replace_default_for_test(runtime)
    registry = Phronomy::MultiAgent::AdmissionRegistry.for(runtime)
    owner = Object.new
    registry.admit!(owner)
    expect { Phronomy::Runtime.reset_default!(timeout: 0) }
      .to raise_error(Phronomy::RuntimeShutdownError, /cleanup is incomplete/)
    expect(Phronomy::Runtime.instance).to equal(runtime)
    expect(runtime.shutdown.cleanup_complete?).to be(false)
    expect { registry.admit!(Object.new) }.to raise_error(Phronomy::RuntimeShutdownError)
  ensure
    registry&.release!(owner)
    Phronomy::Runtime.restore_default_for_test(previous)
  end

  it "still waits for later participants after an earlier participant times out" do
    first = double("busy participant", begin_draining: nil, wait_until_idle: false)
    second = double("idle participant", begin_draining: nil)
    expect(second).to receive(:wait_until_idle).and_return(true)
    runtime.__register_shutdown_participant(key: :first, participant: first)
    runtime.__register_shutdown_participant(key: :second, participant: second)
    expect(runtime.shutdown(timeout: 0).cleanup_complete?).to be(false)
  end

  %i[begin_draining wait_until_idle].each do |operation|
    it "continues cleanup and reports incomplete cleanup when #{operation} raises" do
      failure = RuntimeError.new("participant failed")
      first = double("failed participant", begin_draining: nil, wait_until_idle: true)
      allow(first).to receive(operation).and_raise(failure)
      second = double("healthy participant")
      expect(second).to receive(:begin_draining).ordered
      expect(second).to receive(:wait_until_idle).ordered.and_return(true)
      runtime.__register_shutdown_participant(key: :first, participant: first)
      runtime.__register_shutdown_participant(key: :second, participant: second)
      expect(runtime.offload).to receive(:shutdown).and_call_original
      result = runtime.shutdown(timeout: 0)
      expect(result.cleanup_complete?).to be(false)
      expect(result.runtime_outcome).to eq(:failed)
      expect(result.error).to equal(failure)
    end
  end

  it "retains the original EventLoop failure if participant closure also fails" do
    participant = double("failed participant", wait_until_idle: true)
    allow(participant).to receive(:begin_draining).and_raise("closure failed")
    runtime.__register_shutdown_participant(key: :failed, participant: participant)
    failure = RuntimeError.new("original failure")
    expect { runtime.__event_loop_failed(failure) }.not_to raise_error
    result = runtime.shutdown
    expect(result.error).to equal(failure)
    expect(result.cleanup_complete?).to be(false)
  end
end

RSpec.describe "Coordination admission ownership" do
  let(:registry) { Phronomy::MultiAgent::AdmissionRegistry.for(Phronomy::Runtime.instance) }
  let(:store) { Phronomy::Persistence.in_memory }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) { agent_definition id: "shutdown-participant-agent", version: 1 }
  end
  let(:agent) { agent_class.create(persistence: store) }
  let(:runner) { Phronomy::MultiAgent::HandoffRunner.new(main_agent: agent) }
  let(:team) do
    Class.new(Phronomy::MultiAgent::TeamCoordinator) do
      team_definition id: "shutdown-participant-team", version: 1
    end.create(persistence: store)
  end

  it "releases Handoff admission after an exception so a later call can enter" do
    allow(runner).to receive(:load_state).and_raise(ArgumentError, "failed after admission")
    2.times do
      expect { runner.invoke("work") }.to raise_error(ArgumentError, /failed after admission/)
    end
    expect(registry.idle?).to be(true)
  end

  it "does not release another Handoff call when admission was rejected" do
    registry.admit!(agent)
    expect { runner.invoke("work") }.to raise_error(Phronomy::HandoffError)
    expect(registry.idle?).to be(false)
  ensure
    registry.release!(agent)
  end

  it "releases Team admission after an exception so a later call can enter" do
    2.times do
      expect { team.invoke("work") }.to raise_error(Phronomy::ConfigurationError, /Team pool agent is missing/)
    end
    expect(registry.idle?).to be(true)
  end

  it "does not release another Team call when admission was rejected" do
    registry.admit!(team)
    expect { team.invoke("work") }.to raise_error(Phronomy::HandoffError)
    expect(registry.idle?).to be(false)
  ensure
    registry.release!(team)
  end

  it "makes cached Handoff and Team callers reject invocation after EventLoop failure" do
    runner
    team
    Phronomy::Runtime.instance.__event_loop_failed(RuntimeError.new("EventLoop failed"))
    expect { runner.invoke("work") }.to raise_error(Phronomy::RuntimeShutdownError)
    expect { team.invoke("work") }.to raise_error(Phronomy::RuntimeShutdownError)
  end
end
