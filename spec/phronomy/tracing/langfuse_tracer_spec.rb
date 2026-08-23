# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Phronomy::Tracing::LangfuseTracer do
  let(:public_key) { "pk-test-key" }
  let(:secret_key) { "sk-test-key" }
  let(:host) { "https://cloud.langfuse.com" }
  subject(:tracer) { described_class.new(public_key: public_key, secret_key: secret_key, host: host) }

  it "is a subclass of Tracing::Base" do
    expect(described_class).to be < Phronomy::Tracing::Base
  end

  describe "#start_span" do
    it "returns a Hash with the span metadata" do
      span = tracer.start_span("my_op", input: "hello", model: "gpt-4")

      expect(span[:name]).to eq("my_op")
      expect(span[:input]).to eq("hello")
      expect(span[:meta][:model]).to eq("gpt-4")
      expect(span[:id]).to match(/\A[0-9a-f-]{36}\z/)
      expect(span[:trace_id]).to match(/\A[0-9a-f-]{36}\z/)
      expect(span[:start_time]).to be_a(Time)
    end

    it "assigns a unique id and trace_id per call" do
      s1 = tracer.start_span("op1")
      s2 = tracer.start_span("op2")

      expect(s1[:id]).not_to eq(s2[:id])
      expect(s1[:trace_id]).not_to eq(s2[:trace_id])
    end
  end

  describe "#finish_span" do
    let(:expected_auth) do
      "Basic #{Base64.strict_encode64("#{public_key}:#{secret_key}")}"
    end

    it "POSTs a span-create event to the ingestion endpoint" do
      stub = stub_request(:post, "#{host}/api/public/ingestion")
        .with(
          headers: {"Content-Type" => "application/json", "Authorization" => expected_auth}
        )
        .to_return(status: 200, body: '{"successes":[]}')

      span = tracer.start_span("ingest_op", input: "hi")
      tracer.finish_span(span, output: "bye")

      expect(stub).to have_been_requested
    end

    it "sends a payload with the span name and timestamps" do
      posted_bodies = []
      stub_request(:post, "#{host}/api/public/ingestion")
        .with { |req|
          posted_bodies << JSON.parse(req.body)
          true
        }
        .to_return(status: 200, body: "{}")

      span = tracer.start_span("timed_op")
      tracer.finish_span(span, output: "result")

      body = posted_bodies.first["batch"].first["body"]
      expect(body["name"]).to eq("timed_op")
      expect(body["startTime"]).to be_a(String)
      expect(body["endTime"]).to be_a(String)
    end

    it "sets open_timeout and read_timeout on the HTTP connection" do
      observed_timeouts = []
      stub_request(:post, "#{host}/api/public/ingestion")
        .to_return(status: 200, body: "{}")

      # Intercept Net::HTTP#open_timeout= and read_timeout= calls
      allow_any_instance_of(Net::HTTP).to receive(:open_timeout=) { |_inst, v| observed_timeouts << [:open, v] }
      allow_any_instance_of(Net::HTTP).to receive(:read_timeout=) { |_inst, v| observed_timeouts << [:read, v] }

      span = tracer.start_span("timed_request")
      tracer.finish_span(span, output: "ok")

      expect(observed_timeouts).to include([:open, 3])
      expect(observed_timeouts).to include([:read, 5])
    end

    it "includes the output in the request body on success" do
      posted_bodies = []
      stub_request(:post, "#{host}/api/public/ingestion")
        .with { |req|
          posted_bodies << JSON.parse(req.body)
          true
        }
        .to_return(status: 200, body: "{}")

      span = tracer.start_span("success_op")
      tracer.finish_span(span, output: "my_output")

      batch = posted_bodies.first["batch"]
      expect(batch.first["body"]["output"]).to eq("my_output")
    end

    it "sets level to ERROR and clears output on error" do
      posted_bodies = []
      stub_request(:post, "#{host}/api/public/ingestion")
        .with { |req|
          posted_bodies << JSON.parse(req.body)
          true
        }
        .to_return(status: 200, body: "{}")

      span = tracer.start_span("failing_op")
      tracer.finish_span(span, error: RuntimeError.new("kaboom"))

      batch = posted_bodies.first["batch"]
      body = batch.first["body"]
      expect(body["level"]).to eq("ERROR")
      expect(body["statusMessage"]).to eq("kaboom")
      expect(body["output"]).to be_nil
    end

    it "includes token usage when provided" do
      posted_bodies = []
      stub_request(:post, "#{host}/api/public/ingestion")
        .with { |req|
          posted_bodies << JSON.parse(req.body)
          true
        }
        .to_return(status: 200, body: "{}")

      usage = Phronomy::TokenUsage.new(input: 20, output: 10, cached: 0, cache_creation: 0)
      span = tracer.start_span("usage_op")
      tracer.finish_span(span, usage: usage)

      body = posted_bodies.first["batch"].first["body"]
      expect(body["usage"]["input"]).to eq(20)
      expect(body["usage"]["output"]).to eq(10)
      expect(body["usage"]["total"]).to eq(30)
    end
    it "warns and does not re-raise network ingestion errors" do
      stub_request(:post, "#{host}/api/public/ingestion").to_raise(SocketError)

      span = tracer.start_span("net_error_op")
      expect {
        tracer.finish_span(span, output: "ok")
      }.to output(/\[Phronomy::LangfuseTracer\] Ingestion failed: SocketError/).to_stderr
    end
  end

  describe "#trace (inherited from Base)" do
    it "wraps the block in a span and returns the block value" do
      stub_request(:post, "#{host}/api/public/ingestion")
        .to_return(status: 200, body: "{}")

      result = tracer.trace("trace_op", input: "in") { ["out", nil] }

      expect(result).to eq("out")
    end

    it "sends error span when the block raises" do
      posted_bodies = []
      stub_request(:post, "#{host}/api/public/ingestion")
        .with { |req|
          posted_bodies << JSON.parse(req.body)
          true
        }
        .to_return(status: 200, body: "{}")

      expect {
        tracer.trace("raise_op") { raise "oops" }
      }.to raise_error("oops")

      body = posted_bodies.first["batch"].first["body"]
      expect(body["level"]).to eq("ERROR")
    end
  end

  describe "self-hosted instance" do
    let(:host) { "http://my-langfuse.internal" }
    subject(:tracer) do
      described_class.new(public_key: public_key, secret_key: secret_key, host: host)
    end

    it "sends requests to the configured host" do
      stub = stub_request(:post, "#{host}/api/public/ingestion")
        .to_return(status: 200, body: "{}")

      span = tracer.start_span("op")
      tracer.finish_span(span)

      expect(stub).to have_been_requested
    end
  end

  # Regression test for Issue #61:
  # LangfuseTracer#ingest must reuse a persistent HTTP connection rather than
  # creating a new Net::HTTP object on every finish_span call.
  describe "HTTP connection reuse (Issue #61)" do
    it "creates only one Net::HTTP object when finish_span is called multiple times (Issue #61)" do
      stub_request(:post, "#{host}/api/public/ingestion")
        .to_return(status: 200, body: "{}")

      http_new_count = 0
      allow(Net::HTTP).to receive(:new).and_wrap_original do |orig, *args|
        http_new_count += 1
        orig.call(*args)
      end

      span1 = tracer.start_span("op1")
      tracer.finish_span(span1, output: "out1")
      span2 = tracer.start_span("op2")
      tracer.finish_span(span2, output: "out2")

      expect(http_new_count).to eq(1)
    end

    it "serializes concurrent access to one cached Net::HTTP connection" do
      state_mutex = Mutex.new
      active_requests = 0
      max_active_requests = 0

      fake_http = Object.new
      fake_http.define_singleton_method(:request) do |_request|
        state_mutex.synchronize do
          active_requests += 1
          max_active_requests = [max_active_requests, active_requests].max
        end
        sleep 0.05
        Object.new
      ensure
        state_mutex.synchronize { active_requests -= 1 }
      end

      allow(tracer).to receive(:build_http).and_return(fake_http)

      gate = Queue.new
      spans = [
        tracer.start_span("concurrent-1"),
        tracer.start_span("concurrent-2")
      ]
      threads = spans.map do |span|
        Thread.new do
          gate.pop
          tracer.finish_span(span, output: "ok")
        end
      end

      2.times { gate << true }
      threads.each(&:value)

      expect(max_active_requests).to eq(1)
    ensure
      threads&.each { |thread| thread.join(1) }
    end
  end
end
