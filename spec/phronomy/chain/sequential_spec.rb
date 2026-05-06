# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Chain::Sequential do
  # Minimal Runnable doubles used as pipeline steps.
  def make_step(transform)
    Class.new do
      include Phronomy::Runnable
      define_method(:invoke) { |input, config: {}| transform.call(input) }
    end.new
  end

  let(:double_step)    { make_step(->(x) { x * 2 }) }
  let(:increment_step) { make_step(->(x) { x + 1 }) }
  let(:to_s_step)      { make_step(->(x) { x.to_s }) }

  subject(:seq) { described_class.new([double_step, increment_step]) }

  # ---- #invoke ---------------------------------------------------------------

  describe "#invoke" do
    it "pipes steps in order" do
      # 3 → double → 6 → increment → 7
      expect(seq.invoke(3)).to eq(7)
    end

    it "passes the config down to each step" do
      cfg = {foo: :bar}
      step = Class.new do
        include Phronomy::Runnable
        attr_reader :last_config
        def invoke(input, config: {})
          @last_config = config
          input
        end
      end.new

      described_class.new([step]).invoke("x", config: cfg)
      expect(step.last_config).to eq(cfg)
    end

    it "works with a single step" do
      expect(described_class.new([double_step]).invoke(4)).to eq(8)
    end

    it "works with three steps" do
      three = described_class.new([double_step, increment_step, to_s_step])
      expect(three.invoke(3)).to eq("7")
    end
  end

  # ---- #stream ---------------------------------------------------------------

  describe "#stream" do
    it "streams only the last step and yields each chunk" do
      streaming_step = Class.new do
        include Phronomy::Runnable
        def invoke(input, config: {}) = input.upcase
        def stream(input, config: {}, &block)
          input.chars.each { |c| block.call(c) }
          input.upcase
        end
      end.new

      # to_s_step converts 3→"3", then streaming_step.stream("3") yields "3"
      seq_with_stream = described_class.new([to_s_step, streaming_step])
      chunks = []
      result = seq_with_stream.stream(3) { |c| chunks << c }

      expect(chunks).to eq(["3"])
      expect(result).to eq("3")
    end

    it "executes preceding steps synchronously before streaming" do
      call_order = []

      step_a = Class.new do
        include Phronomy::Runnable
        define_method(:invoke) { |input, config: {}| call_order << :a; input + 10 }
      end.new

      step_b = Class.new do
        include Phronomy::Runnable
        define_method(:invoke) { |input, config: {}| call_order << :b; input.to_s }
        define_method(:stream) { |input, config: {}, &block| call_order << :b_stream; block&.call(input.to_s); input.to_s }
      end.new

      described_class.new([step_a, step_b]).stream(5) { |_| }
      expect(call_order).to eq([:a, :b_stream])
    end

    it "returns the final step result without a block" do
      expect(described_class.new([double_step]).stream(3)).to eq(6)
    end
  end

  # ---- #>> flattening --------------------------------------------------------

  describe "#>>" do
    it "returns a new Sequential" do
      result = seq >> to_s_step
      expect(result).to be_a(described_class)
    end

    it "flattens into a single Sequential (no nesting)" do
      three = seq >> to_s_step
      # Internally there should be exactly 3 steps, not a nested Sequential.
      steps = three.instance_variable_get(:@steps)
      expect(steps.length).to eq(3)
      expect(steps.none? { |s| s.is_a?(described_class) }).to be true
    end

    it "executes all steps in the correct order after flattening" do
      three = seq >> to_s_step
      expect(three.invoke(3)).to eq("7")
    end
  end

  # ---- inherited Runnable methods --------------------------------------------

  describe "#batch" do
    it "processes multiple inputs" do
      expect(seq.batch([1, 2, 3])).to eq([3, 5, 7])
    end
  end
end
