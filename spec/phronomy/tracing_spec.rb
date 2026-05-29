# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Tracing::Base do
  let(:tracer) do
    Class.new(described_class) do
      attr_reader :started, :finished

      def start_span(name, **attrs)
        @started = {name: name, attrs: attrs}
        @started
      end

      def finish_span(span, output: nil, usage: nil, error: nil)
        @finished = {span: span, output: output, usage: usage, error: error}
      end
    end.new
  end

  describe "#trace" do
    it "calls start_span and finish_span around the block" do
      result = tracer.trace("my_op", input: "hello") { ["world", nil] }
      expect(result).to eq("world")
      expect(tracer.started[:name]).to eq("my_op")
      expect(tracer.finished[:output]).to eq("world")
      expect(tracer.finished[:error]).to be_nil
      # Verify the span object returned by start_span is forwarded to finish_span.
      expect(tracer.finished[:span]).to be(tracer.started)
    end

    it "passes usage to finish_span" do
      usage = Phronomy::TokenUsage.new(input: 10, output: 5, cached: 2, cache_creation: 0)
      tracer.trace("op", input: "x") { ["result", usage] }
      expect(tracer.finished[:usage]).to eq(usage)
    end

    it "passes extra metadata to start_span" do
      tracer.trace("op", input: "x", model: "gpt-4") { [nil, nil] }
      expect(tracer.started[:attrs]).to include(input: "x", model: "gpt-4")
    end

    it "calls finish_span with the error when the block raises" do
      expect {
        tracer.trace("failing") { raise "boom" }
      }.to raise_error(RuntimeError, "boom")

      expect(tracer.finished[:error]).to be_a(RuntimeError)
      # Verify the original span is forwarded to finish_span even on error.
      expect(tracer.finished[:span]).to be(tracer.started)
    end

    it "re-raises the exception after finishing the span" do
      expect {
        tracer.trace("op") { raise "oops" }
      }.to raise_error("oops")
    end
  end

  describe "#start_span" do
    it "raises NotImplementedError when not overridden" do
      expect { described_class.new.start_span("x") }.to raise_error(NotImplementedError)
    end

    it "includes the calling class name in the error message" do
      expect { described_class.new.start_span("x") }
        .to raise_error(NotImplementedError, "Phronomy::Tracing::Base#start_span is not implemented")
    end
  end

  describe "#finish_span" do
    it "raises NotImplementedError when not overridden" do
      expect { described_class.new.finish_span(nil) }.to raise_error(NotImplementedError)
    end

    it "includes the calling class name in the error message" do
      expect { described_class.new.finish_span(nil) }
        .to raise_error(NotImplementedError, "Phronomy::Tracing::Base#finish_span is not implemented")
    end
  end
end

RSpec.describe Phronomy::Tracing::NullTracer do
  subject(:tracer) { described_class.new }

  it "is a subclass of Tracing::Base" do
    expect(described_class).to be < Phronomy::Tracing::Base
  end

  describe "#start_span" do
    it "returns an object with a name attribute" do
      span = tracer.start_span("test_op")
      expect(span.name).to eq("test_op")
    end
  end

  describe "#finish_span" do
    it "returns nil silently" do
      span = tracer.start_span("op")
      expect(tracer.finish_span(span, output: "result")).to be_nil
    end
  end

  describe "#trace" do
    it "yields and returns the block result without error" do
      result = tracer.trace("op", input: "in") { ["out", nil] }
      expect(result).to eq("out")
    end
  end
end

RSpec.describe "Tracing integration with Configuration" do
  after { Phronomy.reset_configuration! }

  it "defaults to NullTracer" do
    expect(Phronomy.configuration.tracer).to be_a(Phronomy::Tracing::NullTracer)
  end

  it "accepts a custom tracer via configure" do
    custom = Phronomy::Tracing::NullTracer.new
    Phronomy.configure { |c| c.tracer = custom }
    expect(Phronomy.configuration.tracer).to be(custom)
  end
end

RSpec.describe "Runnable#trace helper" do
  let(:runnable) do
    Class.new do
      include Phronomy::Runnable

      def invoke(input, config: {}) = input.upcase
    end.new
  end

  after { Phronomy.reset_configuration! }

  it "delegates to the configured tracer" do
    spans = []
    spy_tracer = Class.new(Phronomy::Tracing::Base) do
      define_method(:start_span) { |name, **|
        spans << name
        Object.new
      }
      define_method(:finish_span) { |*| nil }
    end.new

    Phronomy.configure { |c| c.tracer = spy_tracer }
    runnable.trace("hello_op") { ["done", nil] }
    expect(spans).to include("hello_op")
  end
end
