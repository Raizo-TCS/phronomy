# frozen_string_literal: true

# Tests for Issue #389: unified Filter::Base interface for input, output,
# and tool result filtering.

require "spec_helper"

RSpec.describe Phronomy::Filter::Base do
  let(:upcasing_filter) do
    Class.new(described_class) do
      def call(value, **_context)
        value.to_s.upcase
      end
    end.new
  end

  let(:blocking_filter) do
    Class.new(described_class) do
      def call(value, **_context)
        block!("blocked by filter") if value.to_s.include?("bad")
        value
      end
    end.new
  end

  describe "#call" do
    it "raises NotImplementedError when not overridden" do
      expect { described_class.new.call("x") }.to raise_error(NotImplementedError)
    end

    it "returns the transformed value" do
      expect(upcasing_filter.call("hello")).to eq("HELLO")
    end

    it "passes keyword context through" do
      context_filter = Class.new(described_class) do
        def call(value, tool_name: nil, **_rest)
          tool_name ? "#{value}:#{tool_name}" : value
        end
      end.new
      expect(context_filter.call("result", tool_name: "my_tool")).to eq("result:my_tool")
    end
  end

  describe "#block!" do
    it "raises FilterBlockError with the given reason" do
      expect { blocking_filter.call("bad input") }
        .to raise_error(Phronomy::FilterBlockError, "blocked by filter")
    end

    it "sets #filter on the raised error" do
      blocking_filter.call("bad input")
    rescue Phronomy::FilterBlockError => e
      expect(e.filter).to eq(blocking_filter)
    end
  end
end

RSpec.describe "Agent::Base filter integration (Issue #389)" do
  def build_agent_class
    klass = Class.new(Phronomy::Agent::Base) { model "test" }
    # Stub _invoke_via_fsm to skip the real FSM/LLM pipeline while still
    # exercising the filter layer. Filters run inside _invoke_via_fsm and
    # transform the input before the (stubbed) LLM call returns.
    allow_any_instance_of(klass).to receive(:_invoke_via_fsm) do |agent_self, input, messages: [], thread_id: nil, config: {}|
      filtered = agent_self.send(:run_input_filters!, input)
      user_message = agent_self.send(:extract_message, filtered)
      raw_output = "result:#{user_message}"
      filtered_output = agent_self.send(:run_output_filters!, raw_output)
      {output: filtered_output, messages: [], usage: nil}
    end
    klass
  end

  let(:upcasing_filter) do
    Class.new(Phronomy::Filter::Base) do
      def call(value, **_context)
        value.to_s.upcase
      end
    end.new
  end

  let(:blocking_filter) do
    Class.new(Phronomy::Filter::Base) do
      def call(value, **_context)
        block!("blocked") if value.to_s.include?("secret")
        value
      end
    end.new
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Input filter
  # ──────────────────────────────────────────────────────────────────────────

  describe "#add_input_filter" do
    it "transforms the user input before it reaches _invoke_impl" do
      agent = build_agent_class.new
      agent.add_input_filter(upcasing_filter)
      result = agent.invoke("hello")
      expect(result[:output]).to eq("result:HELLO")
    end

    it "accepts a Class and instantiates it automatically" do
      filter_class = Class.new(Phronomy::Filter::Base) do
        def call(value, **_context) = value.to_s.upcase
      end
      agent = build_agent_class.new
      agent.add_input_filter(filter_class)   # pass the class, not .new
      result = agent.invoke("hello")
      expect(result[:output]).to eq("result:HELLO")
    end

    it "blocks the call when the filter raises FilterBlockError" do
      agent = build_agent_class.new
      agent.add_input_filter(blocking_filter)
      expect { agent.invoke("secret") }.to raise_error(Phronomy::FilterBlockError, "blocked")
    end

    it "chains multiple input filters in registration order" do
      append_filter = Class.new(Phronomy::Filter::Base) do
        def call(value, **_context) = "#{value}!"
      end.new
      agent = build_agent_class.new
      agent.add_input_filter(upcasing_filter)
      agent.add_input_filter(append_filter)
      result = agent.invoke("hi")
      expect(result[:output]).to eq("result:HI!")
    end
  end

  describe ".input_filter (class DSL)" do
    it "applies to every instance when given an instance" do
      klass = build_agent_class
      klass.input_filter(upcasing_filter)
      result = klass.new.invoke("hello")
      expect(result[:output]).to eq("result:HELLO")
    end

    it "accepts a Class and instantiates it automatically" do
      filter_class = Class.new(Phronomy::Filter::Base) do
        def call(value, **_context) = value.to_s.upcase
      end
      klass = build_agent_class
      klass.input_filter(filter_class)   # pass the class, not .new
      result = klass.new.invoke("hello")
      expect(result[:output]).to eq("result:HELLO")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Output filter
  # ──────────────────────────────────────────────────────────────────────────

  describe "#add_output_filter" do
    it "transforms the LLM output before returning it to the caller" do
      agent = build_agent_class.new
      agent.add_output_filter(upcasing_filter)
      result = agent.invoke("hi")
      expect(result[:output]).to eq("RESULT:HI")
    end

    it "blocks when the output filter raises FilterBlockError" do
      klass = build_agent_class  # uses standard stub that returns "result:..."
      # The output "result:anything" does NOT contain "secret", so we use a
      # filter that blocks on "result" to exercise the block path.
      blocker = Class.new(Phronomy::Filter::Base) do
        def call(value, **_context)
          block!("blocked") if value.to_s.include?("result")
          value
        end
      end.new
      agent = klass.new
      agent.add_output_filter(blocker)
      expect { agent.invoke("anything") }.to raise_error(Phronomy::FilterBlockError, "blocked")
    end
  end

  describe ".output_filter (class DSL)" do
    it "applies to every instance" do
      klass = build_agent_class
      klass.output_filter(upcasing_filter)
      result = klass.new.invoke("hi")
      expect(result[:output]).to eq("RESULT:HI")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Tool result filter
  # ──────────────────────────────────────────────────────────────────────────

  describe "#add_tool_result_filter (all-tools form)" do
    it "transforms every tool's return value" do
      tool_class = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "my_tool"
        description "test tool"
        def execute = "raw_result"
      end

      agent_class = Class.new(Phronomy::Agent::Base) do
        model "test"
        tools tool_class
      end

      agent = agent_class.new
      agent.add_tool_result_filter(upcasing_filter)

      wrapped = agent.send(:prepare_tool_class, tool_class)
      expect(wrapped.new.call({})).to eq("RAW_RESULT")
    end
  end

  describe "#add_tool_result_filter (scoped form)" do
    it "transforms only the specified tool's return value" do
      tool_a = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "tool_a"
        description "a"
        def execute = "result_a"
      end
      tool_b = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "tool_b"
        description "b"
        def execute = "result_b"
      end

      agent_class = Class.new(Phronomy::Agent::Base) do
        model "test"
        tools tool_a, tool_b
      end

      agent = agent_class.new
      agent.add_tool_result_filter(tool_a, upcasing_filter)

      wrapped_a = agent.send(:prepare_tool_class, tool_a)
      wrapped_b = agent.send(:prepare_tool_class, tool_b)
      expect(wrapped_a.new.call({})).to eq("RESULT_A")
      expect(wrapped_b.new.call({})).to eq("result_b")
    end
  end

  describe ".tool_result_filter (class DSL)" do
    it "applies to all tools for every instance" do
      tool_class = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "my_tool"
        description "test tool"
        def execute = "raw"
      end

      agent_class = Class.new(Phronomy::Agent::Base) do
        model "test"
        tools tool_class
        tool_result_filter(
          Class.new(Phronomy::Filter::Base) do
            def call(value, **_context) = value.to_s.upcase
          end.new
        )
      end

      wrapped = agent_class.new.send(:prepare_tool_class, tool_class)
      expect(wrapped.new.call({})).to eq("RAW")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Same filter instance reusable across all three sites
  # ──────────────────────────────────────────────────────────────────────────

  describe "reusing the same filter instance at multiple sites" do
    it "applies the same filter to input and output" do
      agent = build_agent_class.new
      f = upcasing_filter
      agent.add_input_filter(f)
      agent.add_output_filter(f)
      result = agent.invoke("hi")
      # input "hi" → "HI", _invoke_impl returns "result:HI", output "result:HI" → "RESULT:HI"
      expect(result[:output]).to eq("RESULT:HI")
    end
  end
end
