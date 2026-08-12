# frozen_string_literal: true

RSpec.describe Phronomy::Task do
  it "completes without creating an execution thread" do
    before = Thread.list.length
    task = described_class.deferred(name: "result")
    task.complete(42)
    expect(task.wait_result).to eq(42)
    expect(Thread.list.length).to eq(before)
  end

  it "propagates failures" do
    task = described_class.deferred
    error = RuntimeError.new("boom")
    task.fail(error)
    expect { task.wait_result }.to raise_error(error)
  end

  it "maps completed values" do
    source = described_class.deferred
    mapped = source.map { |value| value * 2 }
    source.complete(21)
    expect(mapped.wait_result).to eq(42)
  end

  it "invokes on_complete registered before settlement" do
    task = described_class.deferred
    observed = []
    task.on_complete { |value, error| observed << [value, error] }
    task.complete(:ok)
    expect(observed).to eq([[:ok, nil]])
  end
end
