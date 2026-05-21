# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require "opentelemetry-sdk"
require "webmock/rspec"

# Group 16: OpenTelemetry and Langfuse tracer adapters
#
# Factors:
#   F1: tracer_type       = [null_tracer, open_telemetry, langfuse]
#   F2: span_lifecycle    = [success, error]
#   F3: usage_presence    = [with_usage, without_usage]
#   F4: tracer_integration = [standalone, configured_globally]
#
# Generated pairwise cases: 6 (see docs/integration_test_cases_tracing.yaml)
#
# Infeasible cases: none — all 6 are feasible without an external service.
# (LangfuseTracer HTTP calls are stubbed with WebMock.)

RSpec.describe "Group 16: OpenTelemetry and Langfuse tracer adapters", :integration do
  # OTel in-memory exporter shared across OTel test cases.
  let(:otel_exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }

  # Langfuse host used throughout Langfuse test cases.
  let(:langfuse_host) { "https://cloud.langfuse.com" }

  # Sample TokenUsage for "with_usage" cases.
  let(:usage) { Phronomy::TokenUsage.new(input: 10, output: 5, cached: 0, cache_creation: 0) }

  after do
    # Reset OTel provider between examples so spans don't leak across tests.
    if defined?(OpenTelemetry)
      otel_exporter.reset
      OpenTelemetry.tracer_provider = OpenTelemetry::Internal::ProxyTracerProvider.new
    end
    # Reset global phronomy config between examples.
    Phronomy.reset_configuration!
  end

  # ---------------------------------------------------------------------------
  # TC-001: null_tracer + success + with_usage + standalone
  # ---------------------------------------------------------------------------
  it "TC-001: NullTracer succeeds silently with usage (standalone)" do
    tracer = IntegrationFactors.tracer("null_tracer")

    result = tracer.trace("op", input: "in") { ["out", usage] }

    expect(result).to eq("out")
  end

  # ---------------------------------------------------------------------------
  # TC-002: null_tracer + error + without_usage + configured_globally
  # ---------------------------------------------------------------------------
  it "TC-002: NullTracer re-raises error when configured globally" do
    tracer = IntegrationFactors.tracer("null_tracer")
    Phronomy.configure { |c| c.tracer = tracer }

    runnable = Class.new { include Phronomy::Runnable }.new

    expect {
      runnable.trace("failing_op") { raise "boom" }
    }.to raise_error("boom")
  end

  # ---------------------------------------------------------------------------
  # TC-003: open_telemetry + success + without_usage + standalone
  # ---------------------------------------------------------------------------
  it "TC-003: OpenTelemetryTracer emits a finished span on success" do
    tracer = IntegrationFactors.tracer("open_telemetry", exporter: otel_exporter)

    result = tracer.trace("ot_success_op", input: "hello") { ["world", nil] }

    expect(result).to eq("world")
    finished = otel_exporter.finished_spans
    expect(finished.size).to eq(1)
    expect(finished.first.name).to eq("ot_success_op")
    # Successful spans have UNSET status by default (OTel convention)
    expect(finished.first.status.code).to eq(OpenTelemetry::Trace::Status::UNSET)
  end

  # ---------------------------------------------------------------------------
  # TC-004: open_telemetry + error + with_usage + configured_globally
  # ---------------------------------------------------------------------------
  it "TC-004: OpenTelemetryTracer marks span ERROR when configured globally and block raises" do
    tracer = IntegrationFactors.tracer("open_telemetry", exporter: otel_exporter)
    Phronomy.configure { |c| c.tracer = tracer }

    runnable = Class.new { include Phronomy::Runnable }.new

    expect {
      runnable.trace("ot_error_op") { raise "oops" }
    }.to raise_error("oops")

    finished = otel_exporter.finished_spans
    expect(finished.size).to eq(1)
    expect(finished.first.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
  end

  # ---------------------------------------------------------------------------
  # TC-005: langfuse + success + with_usage + configured_globally
  # ---------------------------------------------------------------------------
  it "TC-005: LangfuseTracer sends span-create with usage when configured globally" do
    posted_bodies = []
    stub_request(:post, "#{langfuse_host}/api/public/ingestion")
      .with { |req| posted_bodies << JSON.parse(req.body) }
      .to_return(status: 200, body: "{}")

    tracer = IntegrationFactors.tracer("langfuse")
    Phronomy.configure { |c|
      c.tracer = tracer
      c.trace_pii = true
    }

    runnable = Class.new { include Phronomy::Runnable }.new
    result = runnable.trace("lf_success_op", input: "query") { ["answer", usage] }

    expect(result).to eq("answer")
    body = posted_bodies.first["batch"].first["body"]
    expect(body["name"]).to eq("lf_success_op")
    expect(body["input"]).to eq("query")
    expect(body["output"]).to eq("answer")
    expect(body["usage"]["input"]).to eq(10)
    expect(body["usage"]["output"]).to eq(5)
    expect(body["level"]).to be_nil
  end

  # ---------------------------------------------------------------------------
  # TC-006: langfuse + error + without_usage + standalone
  # ---------------------------------------------------------------------------
  it "TC-006: LangfuseTracer sends ERROR span when block raises (standalone)" do
    posted_bodies = []
    stub_request(:post, "#{langfuse_host}/api/public/ingestion")
      .with { |req| posted_bodies << JSON.parse(req.body) }
      .to_return(status: 200, body: "{}")

    tracer = IntegrationFactors.tracer("langfuse")

    expect {
      tracer.trace("lf_error_op") { raise "langfuse_fail" }
    }.to raise_error("langfuse_fail")

    body = posted_bodies.first["batch"].first["body"]
    expect(body["level"]).to eq("ERROR")
    expect(body["statusMessage"]).to eq("langfuse_fail")
    expect(body["output"]).to be_nil
    expect(body["usage"]).to be_nil
  end
end
