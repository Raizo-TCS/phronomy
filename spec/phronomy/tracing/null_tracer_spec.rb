# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Tracing::NullTracer do
  subject(:tracer) { described_class.new }

  # Contract tests: verify that NullTracer satisfies the tracer interface (Issue #212).
  it_behaves_like "a tracer" do
    let(:tracer) { described_class.new }
  end

  it "is a subclass of Tracing::Base" do
    expect(described_class).to be < Phronomy::Tracing::Base
  end

  describe "#start_span" do
    it "returns an object responding to :name" do
      span = tracer.start_span("my_op")
      expect(span.name).to eq("my_op")
    end

    it "ignores extra keyword arguments" do
      expect { tracer.start_span("op", input: "x", model: "gpt-4") }.not_to raise_error
    end

    # Regression test for Issue #53: the span object must not use OpenStruct,
    # which silently returns nil for any unknown method call (including typos).
    it "raises NoMethodError for unknown attributes (not silently nil)" do
      span = tracer.start_span("check_op")
      expect { span.nonexistent_attribute }.to raise_error(NoMethodError)
    end
  end

  describe "#finish_span" do
    it "returns nil" do
      span = tracer.start_span("op")
      expect(tracer.finish_span(span, output: "result")).to be_nil
    end
  end

  describe "#trace" do
    it "yields the span and returns the block result" do
      result = tracer.trace("op") { |_span| "block_result" }
      expect(result).to eq("block_result")
    end
  end
end
