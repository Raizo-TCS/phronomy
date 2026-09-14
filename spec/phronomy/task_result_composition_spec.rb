# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe "TaskResult composition contracts" do
  let(:result_class) { Phronomy::TaskResult }

  it "removes the old public Task constant" do
    expect(Phronomy.const_defined?(:Task, false)).to be false
  end

  it "keeps a map-returned result as a value and flattens only flat_map" do
    inner = result_class.deferred
    source = result_class.completed(1)
    expect(source.map { inner }.wait_result).to equal(inner)
    flattened = source.flat_map { inner }
    expect(flattened).not_to be_done
    inner.complete(42)
    expect(flattened.wait_result).to eq(42)
  end

  it "rejects missing blocks at registration and a wrong flat_map return in the derived result" do
    source = result_class.completed(1)
    expect { source.map }.to raise_error(ArgumentError)
    expect { source.flat_map }.to raise_error(ArgumentError)
    expect { source.flat_map { 42 }.wait_result }.to raise_error(TypeError, /TaskResult/)
    expect(source.wait_result).to eq(1)
  end

  [:map, :flat_map].each do |method|
    [true, false].each do |settled_before|
      it "preserves #{method} source cancellation and error identity (already settled: #{settled_before})" do
        source = result_class.deferred
        error = Phronomy::CancellationError.new("original reason")
        source.cancel!(error) if settled_before
        derived = source.public_send(method) { raise "must not execute" }
        source.cancel!(error) unless settled_before
        expect(derived.status).to eq(:cancelled)
        expect { derived.wait_result }.to raise_error { |actual| expect(actual).to equal(error) }
      end
    end
  end

  it "preserves an inner cancellation and accepts subclasses" do
    inner = Class.new(result_class).deferred
    derived = result_class.completed(1).flat_map { inner }
    error = Phronomy::CancellationError.new("inner cancelled")
    inner.cancel!(error)
    expect(derived.status).to eq(:cancelled)
    expect { derived.wait_result }.to raise_error { |actual| expect(actual).to equal(error) }
  end

  it "keeps failed CancellationError values and raised application errors as failures" do
    error = Phronomy::CancellationError.new("app error")
    [:map, :flat_map].each do |method|
      from_failure = result_class.failed(error).public_send(method) { raise "not called" }
      from_block = result_class.completed(1).public_send(method) { raise error }
      [from_failure, from_block].each do |derived|
        expect(derived.status).to eq(:failed)
        expect { derived.wait_result }.to raise_error { |actual| expect(actual).to equal(error) }
      end
    end
  end

  it "validates the complete wait list before observing any source" do
    source = result_class.deferred
    expect(source).not_to receive(:on_complete)
    expect { result_class.all_settled([source, :bad]) }.to raise_error(TypeError, /\[1\]/)
    expect { result_class.all_settled(nil) }.to raise_error(TypeError)
  end

  it "collects reverse completion, duplicate positions, nil, failures and cancellation in input order" do
    a = result_class.deferred
    b = result_class.deferred
    error = RuntimeError.new("failed")
    cancelled = result_class.deferred.cancel!(Phronomy::CancellationError.new("stopped"))
    inputs = [a, b, a, result_class.failed(error), cancelled, result_class.completed(nil)]
    combined = result_class.all_settled(inputs)
    inputs.clear
    b.complete(:second)
    expect(combined).not_to be_done
    value = {answer: 1}
    a.complete(value)
    outcomes = combined.wait_result
    expect(outcomes.map(&:index)).to eq([0, 1, 2, 3, 4, 5])
    expect(outcomes.map(&:status)).to eq([:completed, :completed, :completed, :failed, :cancelled, :completed])
    expect(outcomes[0].value).to equal(value)
    expect(outcomes[2].value).to equal(value)
    expect(outcomes[3].error).to equal(error)
    expect(outcomes).to be_frozen
    expect(outcomes).to all(be_frozen)
    expect(value).not_to be_frozen
    expect(result_class.all_settled([]).wait_result).to eq([])
  end

  it "does not lose simultaneous completion or complete more than once" do
    sources = Array.new(30) { result_class.deferred }
    combined = result_class.all_settled(sources + sources.reverse)
    notifications = Queue.new
    combined.on_complete { notifications << true }
    threads = sources.each_with_index.map { |source, i| Thread.new { source.complete(i) } }
    threads.each(&:join)
    expect(combined.wait_result.map(&:value)).to eq((0...30).to_a + (0...30).to_a.reverse)
    expect(notifications.size).to eq(1)
  end

  it "keeps wait_result timeout local to one observer" do
    source = result_class.deferred
    derived = source.map { |value| value * 2 }
    expect { derived.wait_result(timeout: 0) }.to raise_error(Phronomy::TimeoutError)
    expect(source).not_to be_done
    source.complete(21)
    expect(derived.wait_result).to eq(42)
  end

  it "tracks an owned flat_map worker after logical cancellation" do
    started = Queue.new
    release = Queue.new
    physical = Queue.new
    token = Phronomy::Concurrency::CancellationToken.new
    derived = result_class.completed(1).flat_map do
      Phronomy::Blocking.call_async(cancellation_token: token) do
        started << true
        release.pop
      end
    end
    derived.on_physical_complete { physical << true }
    Timeout.timeout(2) { started.pop }
    token.cancel!
    expect(derived.status).to eq(:cancelled)
    expect(derived.physical_complete?).to be false
    release << true
    Timeout.timeout(2) { physical.pop }
    expect(derived.physical_complete?).to be true
  ensure
    release << true if release
  end
end
