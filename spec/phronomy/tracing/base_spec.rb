# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Tracing::Base do
  # A minimal concrete subclass used to test #trace without depending on NullTracer.
  let(:span_class) { Struct.new(:name) }

  let(:concrete_tracer_class) do
    span_klass = span_class
    Class.new(described_class) do
      define_method(:start_span) { |name, **| span_klass.new(name) }
      define_method(:finish_span) { |_span, **| nil }
    end
  end

  subject(:base_tracer) { described_class.new }
  subject(:tracer) { concrete_tracer_class.new }

  describe "#start_span" do
    it "raises NotImplementedError because Base is abstract" do
      expect { base_tracer.start_span("op") }.to raise_error(NotImplementedError)
    end

    it "includes the class and method name in the message" do
      expect { base_tracer.start_span("op") }.to raise_error(NotImplementedError, /#start_span/)
    end
  end

  describe "#finish_span" do
    it "raises NotImplementedError because Base is abstract" do
      fake_span = Object.new
      expect { base_tracer.finish_span(fake_span) }.to raise_error(NotImplementedError)
    end

    it "includes the class and method name in the message" do
      fake_span = Object.new
      expect { base_tracer.finish_span(fake_span) }.to raise_error(NotImplementedError, /#finish_span/)
    end
  end

  describe "#trace" do
    it "yields the span returned by #start_span" do
      yielded = nil
      tracer.trace("op") { |span|
        yielded = span
        ["result", nil]
      }
      expect(yielded).to be_a(span_class)
    end

    it "returns the block's first return value" do
      result = tracer.trace("op") { |_span| ["block_result", nil] }
      expect(result).to eq("block_result")
    end

    it "calls #finish_span with the output on success" do
      finished_with = nil
      allow(tracer).to receive(:finish_span) { |_span, **kwargs| finished_with = kwargs }
      tracer.trace("op") { |_span| ["out", nil] }
      expect(finished_with[:output]).to eq("out")
    end

    it "calls #finish_span with the error and re-raises on failure" do
      error = RuntimeError.new("boom")
      finished_with = nil
      allow(tracer).to receive(:finish_span) { |_span, **kwargs| finished_with = kwargs }

      expect { tracer.trace("op") { |_span| raise error } }.to raise_error(RuntimeError, "boom")
      expect(finished_with[:error]).to be(error)
    end

    it "calls #start_span with the given name" do
      expect(tracer).to receive(:start_span).with("my_op", input: nil).and_call_original
      tracer.trace("my_op") { |_span| [nil, nil] }
    end
  end
end
