# frozen_string_literal: true

require "spec_helper"

# Nightly spec: OpenTelemetry tracer adapter — verifies spans are emitted and
# recorded by the SDK InMemorySpanExporter.
#
# Required environment variables:
#   NIGHTLY=1
#
# Run with:
#   bundle exec rspec spec/integration/nightly/otel_spec.rb --tag nightly
#   bundle exec rspec spec/integration/nightly/otel_spec.rb --tag real_backend:otel
#
# Note: requires gem install opentelemetry-sdk before running.
# No external collector is needed; spans are captured in-process.
#
# These tests are skipped locally unless NIGHTLY is set.
# They run automatically in CI via .github/workflows/nightly.yml (real-backend-otel job).

OTEL_AVAILABLE = if ENV["NIGHTLY"]
  begin
    require "opentelemetry-sdk"
    require "opentelemetry/sdk"
    true
  rescue LoadError => e
    warn "Skipping OTEL nightly spec: #{e.message}"
    false
  end
else
  false
end

RSpec.describe "Nightly: OpenTelemetryTracer span export", :nightly, real_backend: :otel do
  before(:all) do
    skip "Skipped: NIGHTLY not set or opentelemetry-sdk not available" unless OTEL_AVAILABLE
  end

  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }

  let(:tracer) do
    OpenTelemetry::SDK.configure do |c|
      c.add_span_processor(
        OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
      )
    end
    Phronomy::Tracing::OpenTelemetryTracer.new(tracer_name: "phronomy-nightly-test")
  end

  after do
    OpenTelemetry.tracer_provider.force_flush
  rescue
    nil
  end

  describe "#start_span / #finish_span round-trip" do
    it "records a finished span with the given name" do
      span = tracer.start_span("test.operation", input: "hello")
      tracer.finish_span(span, output: "world")

      finished = exporter.finished_spans
      expect(finished.length).to be >= 1
      names = finished.map(&:name)
      expect(names).to include("test.operation")
    end

    it "attaches phronomy.input and phronomy.output attributes" do
      span = tracer.start_span("agent.invoke", input: "ping")
      tracer.finish_span(span, output: "pong")

      finished = exporter.finished_spans.last
      expect(finished.attributes["phronomy.input"]).to eq("ping")
      expect(finished.attributes["phronomy.output"]).to eq("pong")
    end

    it "records token usage attributes when usage is provided" do
      usage = double("usage", input: 10, output: 5)
      span = tracer.start_span("llm.complete")
      tracer.finish_span(span, usage: usage)

      finished = exporter.finished_spans.last
      expect(finished.attributes["llm.usage.input_tokens"]).to eq(10)
      expect(finished.attributes["llm.usage.output_tokens"]).to eq(5)
      expect(finished.attributes["llm.usage.total_tokens"]).to eq(15)
    end

    it "records error status when an exception is provided" do
      error = RuntimeError.new("downstream failed")
      span = tracer.start_span("tool.call")
      tracer.finish_span(span, error: error)

      finished = exporter.finished_spans.last
      expect(finished.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
    end
  end

  describe "#trace block helper" do
    it "emits a span that encloses the block and captures the return value" do
      result = tracer.trace("workflow.step", input: "step_input") { "step_output" }

      expect(result).to eq("step_output")
      finished = exporter.finished_spans
      expect(finished.map(&:name)).to include("workflow.step")
    end
  end
end
