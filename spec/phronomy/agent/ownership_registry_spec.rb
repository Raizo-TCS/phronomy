# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::OwnershipRegistry do
  def owned_agent(registry, id)
    agent = instance_double(Phronomy::Agent::Base, agent_id: id,
      __bind_runtime_owner!: nil, __mark_unloaded!: nil)
    registry.load(id, expected_class: Object) { agent }
  end

  def idle_now?(registry)
    registry.wait_until_idle(Process.clock_gettime(Process::CLOCK_MONOTONIC))
  end

  it "keeps an accepted final release pending through the unload transition" do
    registry = described_class.new(environment: Object.new)
    child = owned_agent(registry, "private-child")
    other = owned_agent(registry, "ordinary-owner")
    registry.expect_unload(child)
    registry.begin_draining

    expect(idle_now?(registry)).to be(false)
    expect { registry.reserve_unload(other) }.to raise_error(Phronomy::RuntimeShutdownError)
    transition, start = registry.reserve_unload(child)
    expect(start).to be(true)
    registry.cancel_expected_unload(child)
    expect(idle_now?(registry)).to be(false)
    registry.finish_unload(child, transition, success: true)
    expect(idle_now?(registry)).to be(true)
    expect(registry.get(child.agent_id, expected_class: Object)).to be_nil
    expect(registry.get(other.agent_id, expected_class: Object)).to equal(other)
  end

  it "removes a failed finalizer's pending release without removing the live owner" do
    registry = described_class.new(environment: Object.new)
    child = owned_agent(registry, "private-child")
    registry.expect_unload(child)
    registry.begin_draining

    registry.cancel_expected_unload(child)

    expect(idle_now?(registry)).to be(true)
    expect(registry.get(child.agent_id, expected_class: Object)).to equal(child)
    expect { registry.reserve_unload(child) }.to raise_error(Phronomy::RuntimeShutdownError)
  end

  it "does not register a new final release after shutdown admission closes" do
    registry = described_class.new(environment: Object.new)
    child = owned_agent(registry, "private-child")
    registry.begin_draining

    expect { registry.expect_unload(child) }.to raise_error(Phronomy::RuntimeShutdownError)
    expect(idle_now?(registry)).to be(true)
  end

  it "restores both live owners after an asynchronous interrupt between the two reservations" do
    registry = described_class.new(environment: Object.new)
    parent, child = %w[parent child].map do |id|
      owner = instance_double(Phronomy::Agent::Base, agent_id: id, __bind_runtime_owner!: nil)
      registry.load(id, expected_class: Object) { owner }
    end
    entries = described_class.const_get(:Entry)
    reservations = 0
    allow(entries).to receive(:new).and_wrap_original do |construct, **fields|
      if fields[:state] == :unloading
        reservations += 1
        Thread.current.raise(IOError, "host interrupted") if reservations == 2
      end
      construct.call(**fields)
    end

    expect { registry.unload_idle_pair(parent, child.agent_id) {} }.to raise_error(IOError, "host interrupted")
    expect(registry.get(parent.agent_id, expected_class: Object)).to equal(parent)
    expect(registry.get(child.agent_id, expected_class: Object)).to equal(child)
  end
end
