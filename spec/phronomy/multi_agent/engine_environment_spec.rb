# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::MultiAgent::EngineEnvironment do
  let(:runtime) { Phronomy::Runtime.instance }
  let(:environment) { described_class.new(runtime: runtime) }

  it "constructs and looks up without registering participants or starting resources" do
    expect(runtime).not_to receive(:__register_shutdown_participant)
    expect(environment.existing_ownership).to be_nil
    expect(runtime.__event_loop_if_initialized).to be_nil
  end

  it "shares admission across different connection instances for the same Runtime" do
    other = described_class.new(runtime: runtime)
    owner = Object.new
    environment.admissions.admit!(owner)
    expect { other.admissions.admit!(owner) }.to raise_error(Phronomy::HandoffError)
    expect(other.admissions.release!(owner)).to be(true)
  end

  it "isolates admission between Runtimes" do
    other_runtime = Phronomy::Runtime.new
    other = described_class.new(runtime: other_runtime)
    owner = Object.new
    first = environment.admissions
    second = other.admissions
    first.admit!(owner)
    second.admit!(owner)
    first.release!(owner)
    expect(second.idle?).to be(false)
  ensure
    first&.release!(owner)
    second&.release!(owner)
    other_runtime&.shutdown
  end

  it "recognizes a replacement Runtime without treating another wrapper as a new environment" do
    expect(environment.current?).to be(true)
    expect(described_class.new(runtime: runtime).current?).to be(true)
    Phronomy.reset_runtime!
    expect(environment.current?).to be(false)
  end

  it "submits through the captured Runtime even if the default changes" do
    original = runtime
    environment
    other = Phronomy::Runtime.new
    previous = Phronomy::Runtime.replace_default_for_test(other)
    expect(Phronomy::Execution).to receive(:submit).with(runtime: original, on_full: :raise) do |&operation|
      expect(operation.call).to eq(:cancel_requested)
      :submitted
    end
    expect(environment.submit(on_full: :raise) { :cancel_requested }).to eq(:submitted)
  ensure
    Phronomy::Runtime.restore_default_for_test(previous)
    other&.shutdown
  end

  it "keeps cached registries closed and rejects registration after shutdown" do
    admissions = environment.admissions
    ownership = environment.ownership
    expect(runtime.shutdown.cleanup_complete?).to be(true)
    expect(environment.existing_ownership).to equal(ownership)
    expect { environment.admissions }.to raise_error(Phronomy::RuntimeShutdownError)
    expect { admissions.admit!(Object.new) }.to raise_error(Phronomy::RuntimeShutdownError)
    expect { ownership.fetch("late", klass: Object, create: true, persistence: nil) { Object.new } }
      .to raise_error(Phronomy::RuntimeShutdownError)
  end

  it "executes work on the original worker pool after the default Runtime changes" do
    original = runtime
    environment
    other = Phronomy::Runtime.new
    previous = Phronomy::Runtime.replace_default_for_test(other)
    expect(original).to receive(:offload).and_call_original
    expect(other).not_to receive(:offload)
    result = environment.submit(on_full: :raise) { :finished }
    expect(result.wait_result(timeout: 2)).to eq(:finished)
  ensure
    Phronomy::Runtime.restore_default_for_test(previous)
    other&.shutdown
  end
end
