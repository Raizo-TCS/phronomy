# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Scope cleanup result and retry contract" do
  let(:definition) { Class.new(Phronomy::Agent::Base) { agent_definition id: "scope-cleanup-contract", version: 1 } }
  it "retains only failed owners and allows release retry with the original successful value" do
    owner = free = recovery = nil
    failure = IOError.new("release blocked")
    expect {
      Phronomy::Agent.open_scope do |scope|
        owner = scope.create(definition)
        free = scope.create(definition)
        allow(owner).to receive(:unload!).and_raise(failure)
        expect(free).to receive(:unload!).once.and_call_original
        Phronomy::TaskResult.completed(:answer)
      end
    }.to raise_error(Phronomy::Agent::ScopeCleanupError) { |error|
      recovery = error.scope
      expect(error.result).to eq(:answer)
      expect(error.primary_error).to be_nil
      expect(error.cause).to equal(failure)
    }
    expect { recovery.create(definition) }.to raise_error(Phronomy::Error, /release_failed/)
    allow(owner).to receive(:unload!).and_call_original
    expect(recovery.release!).to be(true)
    expect(recovery.release!).to be(false)
  end

  it "keeps a failed Task error identity, all cleanup failures and a nil result" do
    primary = IOError.new("business failed")
    failures = [IOError.new("first cleanup"), IOError.new("second cleanup")]
    expect {
      Phronomy::Agent.open_scope do |scope|
        failures.each { |failure| allow(scope.create(definition)).to receive(:unload!).and_raise(failure) }
        Phronomy::TaskResult.failed(primary)
      end
    }.to raise_error(Phronomy::Agent::ScopeCleanupError) { |error|
      expect(error.primary_error).to equal(primary)
      expect(error.cause).to equal(primary)
      expect(error.result).to be_nil
      expect(error.failures.map { |f| f[:error] }).to eq(failures)
    }
  end

  it "returns the identical primary exception when cleanup succeeds" do
    error = IOError.new("failed task")
    expect {
      Phronomy::Agent.open_scope { |scope|
        scope.create(definition)
        Phronomy::TaskResult.failed(error)
      }
    }.to raise_error { |raised| expect(raised).to equal(error) }
  end

  it "does not traverse Task arrays or recursively unwrap a Task value" do
    pending = Phronomy::TaskResult.deferred
    value = [pending]
    expect(Phronomy::Agent.open_scope { value }).to equal(value)
    expect(Phronomy::Agent.open_scope { Phronomy::TaskResult.completed(pending) }).to equal(pending)
    expect(pending).not_to be_done
  end

  it "rejects simultaneous release while allowing the first release to finish" do
    owned_scope = entered = unblock = releaser = nil
    Phronomy::Agent.open_scope do |scope|
      owned_scope = scope
      agent = scope.create(definition)
      entered, unblock = Queue.new, Queue.new
      allow(agent).to receive(:unload!).and_wrap_original do |original|
        entered << true
        unblock.pop(timeout: 3)
        original.call
      end
      releaser = Thread.new { scope.release! }
      expect(entered.pop(timeout: 3)).to be(true)
      expect { scope.release! }.to raise_error(Phronomy::Error) { |error| expect(error.code).to eq("agent.scope_busy") }
      unblock << true
      expect(releaser.value).to be(true)
      :done
    end
    expect(owned_scope.release!).to be(false)
  ensure
    unblock&.push(true)
    releaser&.join(3)
  end
end
