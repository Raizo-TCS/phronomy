# frozen_string_literal: true

require "spec_helper"
require "opentelemetry-sdk"

RSpec.describe Phronomy::Tracing::OpenTelemetryTracer do
  # Configure an in-process OTel SDK with a SimpleSpanProcessor and an
  # InMemory exporter so that spans are captured without any network I/O.
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }

  before do
    OpenTelemetry::SDK.configure do |c|
      c.add_span_processor(
        OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
      )
    end
  end

  after do
    exporter.reset
    OpenTelemetry.tracer_provider = OpenTelemetry::Internal::ProxyTracerProvider.new
  end

  subject(:tracer) { described_class.new(tracer_name: "test_tracer") }

  it "is a subclass of Tracing::Base" do
    expect(described_class).to be < Phronomy::Tracing::Base
  end

  describe "#start_span / #finish_span" do
    it "emits a finished span with the given name" do
      span = tracer.start_span("my_op", input: "hello")
      tracer.finish_span(span, output: "world")

      finished = exporter.finished_spans
      expect(finished.size).to eq(1)
      expect(finished.first.name).to eq("my_op")
    end

    it "records the input as a span attribute" do
      span = tracer.start_span("op", input: "the_input")
      tracer.finish_span(span)

      attrs = exporter.finished_spans.first.attributes
      expect(attrs["phronomy.input"]).to eq("the_input")
    end

    it "records extra metadata as span attributes" do
      span = tracer.start_span("op", input: "x", model: "gpt-4")
      tracer.finish_span(span)

      attrs = exporter.finished_spans.first.attributes
      expect(attrs["phronomy.model"]).to eq("gpt-4")
    end

    it "records output as a span attribute on success" do
      span = tracer.start_span("op")
      tracer.finish_span(span, output: "ok_result")

      attrs = exporter.finished_spans.first.attributes
      expect(attrs["phronomy.output"]).to eq("ok_result")
    end

    it "records token usage attributes when usage is present" do
      usage = Phronomy::TokenUsage.new(input: 10, output: 5, cached: 0, cache_creation: 0)
      span = tracer.start_span("op")
      tracer.finish_span(span, usage: usage)

      attrs = exporter.finished_spans.first.attributes
      expect(attrs["llm.usage.input_tokens"]).to eq(10)
      expect(attrs["llm.usage.output_tokens"]).to eq(5)
      expect(attrs["llm.usage.total_tokens"]).to eq(15)
    end
    it "marks span status as ERROR and records exception on error" do
      span = tracer.start_span("failing_op")
      error = RuntimeError.new("something went wrong")
      tracer.finish_span(span, error: error)

      finished_span = exporter.finished_spans.first
      expect(finished_span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
    end
  end

  describe "#trace (inherited from Base)" do
    it "wraps the block in a span and returns the block value" do
      result = tracer.trace("wrap_op", input: "in") { ["out", nil] }

      expect(result).to eq("out")
      expect(exporter.finished_spans.size).to eq(1)
      expect(exporter.finished_spans.first.name).to eq("wrap_op")
    end

    it "finishes the span with error status when the block raises" do
      expect {
        tracer.trace("boom_op") { raise "oops" }
      }.to raise_error("oops")

      finished_span = exporter.finished_spans.first
      expect(finished_span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
    end

    it "records task_id and parent_task_id as span attributes" do
      tracer.trace("task_op", task_id: "T1", parent_task_id: "T0") { ["result", nil] }

      attrs = exporter.finished_spans.first.attributes
      expect(attrs["phronomy.task_id"]).to eq("T1")
      expect(attrs["phronomy.parent_task_id"]).to eq("T0")
    end

    it "establishes parent/child span relationships for nested trace calls" do
      tracer.trace("parent_op") do |_span|
        tracer.trace("child_op") { ["child_result", nil] }
        ["parent_result", nil]
      end

      spans = exporter.finished_spans
      expect(spans.size).to eq(2)

      child_span = spans.find { |s| s.name == "child_op" }
      parent_span = spans.find { |s| s.name == "parent_op" }

      expect(child_span).not_to be_nil
      expect(parent_span).not_to be_nil
      expect(child_span.parent_span_id).to eq(parent_span.span_id)
    end
  end
end
