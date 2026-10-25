# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::AsyncOperation, ".finalize" do
  let(:source) { Phronomy::Concurrency::PhysicalCompletionTask.deferred(name: "source") }
  let(:cleanup) { Phronomy::Concurrency::PhysicalCompletionTask.deferred(name: "cleanup") }
  let(:calls) { [] }
  let(:errors) { [] }
  let(:combined) { RuntimeError.new("combined") }

  def finalize(&start)
    described_class.finalize(name: "owned", cleanup: -> {
      calls << :cleanup
      cleanup
    },
      on_cleanup_error: ->(value, primary, failure) {
        errors << [value, primary, failure]
        combined
      },
      &start || -> { source })
  end

  [:logical_first, :physical_first].each do |order|
    it "waits for both source and cleanup boundaries with #{order}" do
      result = finalize
      if order == :logical_first
        source.complete("value")
        expect(calls).to be_empty
        source.mark_physical_complete!
      else
        source.mark_physical_complete!
        expect(calls).to be_empty
        source.complete("value")
      end
      expect(calls).to eq([:cleanup])
      cleanup.complete(true)
      expect(result).not_to be_done
      expect(result.physical_complete?).to be(false)
      cleanup.mark_physical_complete!
      expect(result.wait_result).to eq("value")
      expect(result.physical_complete?).to be(true)
    end
  end

  it "supports already completed ordinary TaskResults" do
    result = described_class.finalize(name: "inline", cleanup: -> { Phronomy::TaskResult.completed(false) },
      on_cleanup_error: ->(*) { raise "unexpected" }) { Phronomy::TaskResult.completed(42) }
    expect(result.wait_result).to eq(42)
    expect(result.physical_complete?).to be(true)
  end

  it "preserves the original source failure after cleanup" do
    failure = RuntimeError.new("source")
    result = finalize
    source.fail(failure)
    source.mark_physical_complete!
    cleanup.mark_physical_complete!
    expect(result).not_to be_done
    cleanup.complete(true)
    expect { result.wait_result }.to raise_error { |error| expect(error).to equal(failure) }
    expect(errors).to be_empty
  end

  it "preserves source cancellation identity and status after physical completion" do
    failure = Phronomy::CancellationError.new("stop")
    result = finalize
    source.cancel!(failure)
    expect(result).not_to be_done
    source.mark_physical_complete!
    cleanup.complete(true)
    cleanup.mark_physical_complete!
    expect(result.status).to eq(:cancelled)
    expect { result.wait_result }.to raise_error { |error| expect(error).to equal(failure) }
  end

  it "keeps cleanup alive after the returned observer is cancelled" do
    result = finalize
    result.cancel!
    source.complete("value")
    source.mark_physical_complete!
    expect(calls).to eq([:cleanup])
    expect(result.physical_complete?).to be(false)
    cleanup.complete(true)
    cleanup.mark_physical_complete!
    expect(result.physical_complete?).to be(true)
    expect(result.status).to eq(:cancelled)
  end

  it "runs cleanup after a synchronous startup exception" do
    failure = ArgumentError.new("start")
    result = finalize { raise failure }
    expect(calls).to eq([:cleanup])
    cleanup.complete(true)
    cleanup.mark_physical_complete!
    expect { result.wait_result }.to raise_error { |error| expect(error).to equal(failure) }
  end

  it "runs cleanup after an invalid startup handle" do
    result = finalize { "not a task" }
    cleanup.complete(true)
    cleanup.mark_physical_complete!
    expect { result.wait_result }.to raise_error(TypeError, /operation must return a TaskResult/)
  end

  [false, true].each do |failed|
    it "combines cleanup failure with #{failed ? "a source error" : "the successful value"}" do
      primary = RuntimeError.new("source") if failed
      failure = IOError.new("cleanup")
      result = finalize
      failed ? source.fail(primary) : source.complete("value")
      source.mark_physical_complete!
      cleanup.fail(failure)
      expect(errors).to be_empty
      cleanup.mark_physical_complete!
      expect(errors).to eq([[failed ? nil : "value", primary, failure]])
      expect { result.wait_result }.to raise_error { |error| expect(error).to equal(combined) }
    end
  end

  it "reports cleanup failure even after the observer is cancelled" do
    result = finalize
    result.cancel!
    source.complete("value")
    source.mark_physical_complete!
    failure = IOError.new("cleanup")
    cleanup.fail(failure)
    cleanup.mark_physical_complete!
    expect(errors).to eq([["value", nil, failure]])
    expect(result.status).to eq(:cancelled)
    expect(result.physical_complete?).to be(true)
  end

  [:raise, :invalid_handle].each do |mode|
    it "captures #{mode} during cleanup startup" do
      failure = IOError.new("cleanup startup")
      result = described_class.finalize(name: "bad cleanup",
        cleanup: -> { (mode == :raise) ? raise(failure) : nil },
        on_cleanup_error: ->(_value, _primary, error) { error }) { Phronomy::TaskResult.completed(1) }
      expect { result.wait_result }.to raise_error((mode == :raise) ? IOError : TypeError)
      expect(result.physical_complete?).to be(true)
    end
  end

  it "settles even when the owner's error policy raises" do
    failure = RuntimeError.new("policy")
    result = described_class.finalize(name: "bad policy",
      cleanup: -> { Phronomy::TaskResult.failed(IOError.new("cleanup")) },
      on_cleanup_error: ->(*) { raise failure }) { Phronomy::TaskResult.completed(1) }
    expect { result.wait_result }.to raise_error { |error| expect(error).to equal(failure) }
    expect(result.physical_complete?).to be(true)
  end

  it "rejects an invalid error policy value without a pending result" do
    result = described_class.finalize(name: "bad policy",
      cleanup: -> { Phronomy::TaskResult.failed(IOError.new("cleanup")) },
      on_cleanup_error: ->(*) {}) { Phronomy::TaskResult.completed(1) }
    expect { result.wait_result }.to raise_error(TypeError, /error policy/)
    expect(result.physical_complete?).to be(true)
  end

  it "claims cleanup once when logical and physical callbacks race or repeat" do
    callbacks = {}
    allow(source).to receive(:on_complete) { |&callback| callbacks[:logical] = callback }
    allow(source).to receive(:on_physical_complete) { |&callback| callbacks[:physical] = callback }
    result = finalize
    threads = [Thread.new { 10.times { callbacks.fetch(:logical).call("first", nil) } },
      Thread.new { 10.times { callbacks.fetch(:physical).call } }]
    threads.each { |thread| expect(thread.join(2)).not_to be_nil }
    expect(calls).to eq([:cleanup])
    cleanup.complete(true)
    cleanup.mark_physical_complete!
    callbacks.fetch(:logical).call("later", nil)
    callbacks.fetch(:physical).call
    expect(result.wait_result).to eq("first")
  end

  it "does not bind mandatory cleanup to a cancelled Execution scope" do
    token = Phronomy::Concurrency::CancellationToken.new
    owned = nil
    parent = Phronomy::Execution.run_async([1], cancellation_token: token) do |_input, _context|
      owned = finalize
    end
    token.cancel!
    source.complete("value")
    source.mark_physical_complete!
    expect(calls).to eq([:cleanup])
    expect(owned.physical_complete?).to be(false)
    cleanup.complete(true)
    cleanup.mark_physical_complete!
    expect(owned.physical_complete?).to be(true)
    expect { parent.wait_result }.to raise_error(Phronomy::ExecutionCancellationError)
  end
end
