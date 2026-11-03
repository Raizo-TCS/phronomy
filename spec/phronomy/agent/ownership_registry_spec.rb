# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::OwnershipRegistry do
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
