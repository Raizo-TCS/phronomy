# frozen_string_literal: true

# Contract tests for Phronomy::Tracing::Base implementations (Issue #212).
#
# Usage:
#   it_behaves_like "a tracer" do
#     let(:tracer) { described_class.new }
#   end
#
# Callers must provide:
#   - `tracer` — a fresh tracer instance
RSpec.shared_examples "a tracer" do
  describe "inheritance" do
    it "is a subclass of Phronomy::Tracing::Base" do
      expect(tracer).to be_a(Phronomy::Tracing::Base)
    end
  end

  describe "interface" do
    it "responds to #start_span" do
      expect(tracer).to respond_to(:start_span)
    end

    it "responds to #finish_span" do
      expect(tracer).to respond_to(:finish_span)
    end

    it "responds to #trace" do
      expect(tracer).to respond_to(:trace)
    end
  end

  describe "#start_span" do
    it "returns an object (span handle)" do
      span = tracer.start_span("test.operation", input: "some input")
      expect(span).not_to be_nil
    end
  end

  describe "#finish_span" do
    it "accepts the span returned by #start_span without raising" do
      span = tracer.start_span("test.finish", input: "x")
      expect { tracer.finish_span(span, output: "result") }.not_to raise_error
    end

    it "accepts an error: kwarg without raising" do
      span = tracer.start_span("test.error", input: "x")
      expect { tracer.finish_span(span, error: RuntimeError.new("oops")) }.not_to raise_error
    end
  end

  describe "#trace" do
    it "yields to the block" do
      yielded = false
      tracer.trace("test.block", input: "x") do
        yielded = true
        ["result", nil]
      end
      expect(yielded).to be true
    end

    it "returns the first element of the block's return value" do
      result = tracer.trace("test.return", input: "x") { ["the result", nil] }
      expect(result).to eq("the result")
    end

    it "re-raises exceptions from the block" do
      expect {
        tracer.trace("test.raise", input: "x") { raise ArgumentError, "bad input" }
      }.to raise_error(ArgumentError, "bad input")
    end
  end
end
