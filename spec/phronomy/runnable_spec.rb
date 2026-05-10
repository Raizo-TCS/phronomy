# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Runnable do
  # Minimal Runnable implementations for testing
  let(:double_step) do
    Class.new do
      include Phronomy::Runnable

      def invoke(input, config: {})
        input * 2
      end
    end.new
  end

  let(:increment_step) do
    Class.new do
      include Phronomy::Runnable

      def invoke(input, config: {})
        input + 1
      end
    end.new
  end

  let(:upcase_step) do
    Class.new do
      include Phronomy::Runnable

      def invoke(input, config: {})
        input.upcase
      end
    end.new
  end

  describe "#invoke" do
    it "raises NotImplementedError when invoke is not implemented in a subclass" do
      bare = Class.new { include Phronomy::Runnable }.new
      expect { bare.invoke("input") }.to raise_error(NotImplementedError)
    end

    it "returns the result for an implemented step" do
      expect(double_step.invoke(3)).to eq(6)
    end
  end

  describe "#stream" do
    it "yields the result to the block" do
      chunks = []
      double_step.stream(4) { |c| chunks << c }
      expect(chunks).to eq([8])
    end

    it "returns the result without a block" do
      expect(double_step.stream(4)).to eq(8)
    end
  end

  describe "#batch" do
    it "processes multiple inputs" do
      results = double_step.batch([1, 2, 3])
      expect(results).to eq([2, 4, 6])
    end

    it "returns an empty array for empty input" do
      expect(double_step.batch([])).to eq([])
    end
  end

  describe "#trace (S05: trace_pii)" do
    let(:recorded_calls) { [] }
    let(:spy_tracer) do
      calls = recorded_calls
      t = double("tracer")
      allow(t).to receive(:trace) do |name, input:, **meta, &block|
        calls << {name: name, input: input}
        block&.call
      end
      t
    end

    let(:traceable_step) do
      Class.new do
        include Phronomy::Runnable

        def invoke(input, config: {})
          trace("step", input: input) { input }
        end
      end.new
    end

    after { Phronomy.reset_configuration! }

    it "passes the real input to the tracer when trace_pii is true (default)" do
      Phronomy.configure { |c| c.tracer = spy_tracer }
      traceable_step.invoke("sensitive data")
      expect(recorded_calls.first[:input]).to eq("sensitive data")
    end

    it "passes [REDACTED] to the tracer when trace_pii is false" do
      Phronomy.configure { |c|
        c.tracer = spy_tracer
        c.trace_pii = false
      }
      traceable_step.invoke("sensitive data")
      expect(recorded_calls.first[:input]).to eq("[REDACTED]")
    end
  end
end
