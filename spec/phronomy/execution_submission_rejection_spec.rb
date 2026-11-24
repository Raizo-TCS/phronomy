# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Execution, "optional submission refusal evidence" do
  let(:refusals) { [] }
  let(:receiver) { ->(error) { refusals << error } }
  let(:legacy_class) do
    Class.new do
      attr_reader :calls

      def initialize
        @calls = 0
      end

      def submit(on_full: :wait)
        @calls += 1
        Phronomy::TaskResult.completed(yield)
      end
    end
  end

  def with_backend(backend)
    previous = described_class.instance_variable_get(:@backend_provider)
    described_class.backend_provider = -> { backend }
    yield
  ensure
    described_class.backend_provider = previous
  end

  it "preserves ordinary submission through a legacy fixed-keyword backend" do
    backend = legacy_class.new
    with_backend(backend) do
      task = described_class.submit(on_full: :raise, on_rejected: receiver) { :completed }
      expect(task.wait_result).to eq(:completed)
    end
    expect(backend.calls).to eq(1)
    expect(refusals).to be_empty
  end

  it "preserves ordinary submission through a legacy fixed-keyword pool" do
    pool = legacy_class.new
    task = Phronomy::ExecutionBinding.submit(pool: pool, on_full: :raise, on_rejected: receiver) { :completed }
    expect(task.wait_result).to eq(:completed)
    expect(pool.calls).to eq(1)
    expect(refusals).to be_empty
  end

  it "preserves fixed-keyword environment overrides that inherit the new capability" do
    environment_class = Class.new(Phronomy::Agent::EngineEnvironment) do
      attr_reader :calls

      def initialize
        @calls = 0
      end

      def submit(on_full: :wait)
        @calls += 1
        Phronomy::TaskResult.completed(yield)
      end
    end
    environment = environment_class.new
    expect(environment.supports_submission_rejection?).to be(true)
    task = described_class.submit_with_rejection_evidence(environment,
      on_full: :raise, on_rejected: receiver) { :completed }
    expect(task.wait_result).to eq(:completed)
    expect(environment.calls).to eq(1)
    expect(refusals).to be_empty
  end

  it "does not manufacture refusal evidence for a legacy backend's actual failure" do
    backend = legacy_class.new
    failure = Phronomy::BackpressureError.new("legacy submission failed")
    with_backend(backend) do
      expect {
        described_class.submit(on_full: :raise, on_rejected: receiver) { raise failure }
      }.to raise_error { |error| expect(error).to equal(failure) }
    end
    expect(backend.calls).to eq(1)
    expect(refusals).to be_empty
  end

  it "does not add a keyword to an undeclared forwarding backend" do
    target = legacy_class.new
    backend = Object.new
    backend.define_singleton_method(:submit) { |**options, &block| target.submit(**options, &block) }
    with_backend(backend) do
      task = described_class.submit(on_full: :raise, on_rejected: receiver) { :completed }
      expect(task.wait_result).to eq(:completed)
    end
    expect(target.calls).to eq(1)
    expect(refusals).to be_empty
  end

  it "keeps a declined evidence capability optional" do
    backend = legacy_class.new
    backend.define_singleton_method(:supports_submission_rejection?) { false }
    with_backend(backend) do
      task = described_class.submit(on_full: :raise, on_rejected: receiver) { :completed }
      expect(task.wait_result).to eq(:completed)
    end
    expect(backend.calls).to eq(1)
  end

  it "forwards refusal evidence from an explicitly supporting backend" do
    failure = Phronomy::BackpressureError.new("confirmed no admission")
    backend = Object.new
    calls = 0
    backend.define_singleton_method(:supports_submission_rejection?) { true }
    backend.define_singleton_method(:submit) do |on_full: :wait, on_rejected: nil, &block|
      calls += 1
      on_rejected&.call(failure)
      raise failure
    end
    with_backend(backend) do
      expect {
        described_class.submit(on_full: :raise, on_rejected: receiver) { raise "must not start" }
      }.to raise_error { |error| expect(error).to equal(failure) }
    end
    expect(calls).to eq(1)
    expect(refusals).to eq([failure])
  end

  it "never probes or retries a supported backend after an ArgumentError" do
    backend = Object.new
    calls = 0
    ran = 0
    backend.define_singleton_method(:supports_submission_rejection?) { true }
    backend.define_singleton_method(:submit) do |on_full: :wait, on_rejected: nil, &block|
      calls += 1
      block.call
      raise ArgumentError, "wrapper failed after starting work"
    end
    with_backend(backend) do
      expect {
        described_class.submit(on_full: :raise, on_rejected: receiver) { ran += 1 }
      }.to raise_error(ArgumentError, "wrapper failed after starting work")
    end
    expect(calls).to eq(1)
    expect(ran).to eq(1)
    expect(refusals).to be_empty
  end

  it "does not inspect evidence capability for an ordinary submission" do
    backend = legacy_class.new
    backend.define_singleton_method(:supports_submission_rejection?) { raise "must not inspect" }
    with_backend(backend) do
      expect(described_class.submit { :completed }.wait_result).to eq(:completed)
    end
    expect(backend.calls).to eq(1)
  end

  it "declares built-in connection capability without accessing Runtime resources" do
    runtime = Object.new
    environment = Phronomy::Agent::EngineEnvironment.new(runtime: runtime)
    expect(environment.supports_submission_rejection?).to be(true)
    expect(Phronomy::ExecutionBinding.supports_submission_rejection?).to be(true)
  end
end
