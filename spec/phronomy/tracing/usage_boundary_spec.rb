# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Tracing usage boundary" do
  after { Phronomy.reset_configuration! }

  it "accepts plain observed counts with no LLM domain object" do
    tracer = instance_double(Phronomy::Tracing::Base)
    counts = {input: 0, output: 7, cached: nil, cache_creation: nil}.freeze
    allow(tracer).to receive(:start_span).and_return(:span)
    expect(tracer).to receive(:finish_span).with(:span, output: "ok", usage: counts)
    expect(Phronomy::Tracing::Base.trace_with(tracer, "plain") { ["ok", counts] }).to eq("ok")
  end

  it "does not infer usage from arbitrary operation output" do
    tracer = instance_double(Phronomy::Tracing::Base)
    allow(tracer).to receive(:start_span).and_return(:span)
    expect(tracer).to receive(:finish_span).with(:span, output: "[REDACTED]", usage: nil, error: nil)
    Phronomy.configure { |config| config.tracer = tracer }
    value = {usage: Object.new}
    expect(Phronomy::Tracing::Automatic.trace("arbitrary") { value }).to equal(value)
  end

  it "preserves task result and closes the span when a caller projection fails" do
    tracer = instance_double(Phronomy::Tracing::Base)
    allow(tracer).to receive(:start_span).and_return(:span)
    expect(tracer).to receive(:finish_span).with(:span, output: "[REDACTED]", usage: nil, error: nil)
    Phronomy.configure do |config|
      config.tracer = tracer
      config.logger = double(warn: nil)
    end
    task = Phronomy::TaskResult.deferred(name: "usage-boundary")
    Phronomy::Tracing::Automatic.observe_task(task, "operation", usage: ->(_value) { raise "bad projection" })
    value = Object.new
    task.complete(value)
    expect(task.wait_result).to equal(value)
  end

  it "has no LLM domain type dependency in Tracing source or RBS" do
    root = File.expand_path("../../..", __dir__)
    files = Dir[File.join(root, "lib/phronomy/tracing/**/*.rb")] + Dir[File.join(root, "sig/phronomy/tracing/**/*.rbs")]
    expect(files).not_to be_empty
    expect(files.select { |path| File.read(path).match?(/LLMAdapter|TokenUsage|usage\.(input|output|cached|cache_creation)\b/) }).to eq([])
  end
end
