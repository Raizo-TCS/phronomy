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

  describe "#>>" do
    it "returns a Phronomy::Chain::Sequential" do
      pipeline = double_step >> increment_step
      expect(pipeline).to be_a(Phronomy::Chain::Sequential)
    end

    it "executes the pipeline in order (double \u2192 increment)" do
      pipeline = double_step >> increment_step
      expect(pipeline.invoke(3)).to eq(7)  # 3*2=6, 6+1=7
    end

    it "works with a 3-step pipeline" do
      # Steps for processing strings
      downcase_step = Class.new do
        include Phronomy::Runnable

        def invoke(input, config: {})
          input.downcase
        end
      end.new

      add_bang = Class.new do
        include Phronomy::Runnable

        def invoke(input, config: {})
          "#{input}!"
        end
      end.new

      pipeline = upcase_step >> downcase_step >> add_bang
      expect(pipeline.invoke("hello")).to eq("hello!")
    end

    it "flattens chained >> into a single Sequential without nesting" do
      pipeline = double_step >> increment_step >> double_step
      expect(pipeline).to be_a(Phronomy::Chain::Sequential)
      expect(pipeline.invoke(2)).to eq(10)  # 2*2=4, 4+1=5, 5*2=10
    end
  end

  describe "#|" do
    it "works as an alias for >>" do
      pipeline = double_step | increment_step
      expect(pipeline).to be_a(Phronomy::Chain::Sequential)
      expect(pipeline.invoke(3)).to eq(7)
    end
  end
end
