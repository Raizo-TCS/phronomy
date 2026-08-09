# frozen_string_literal: true

require "spec_helper"

# ---------------------------------------------------------------------------
# Fault injection tests (Issue #213)
#
# Verifies that the system handles injected failures correctly:
#   1. Error translation at the retry boundary (#204 regression guard)
#   2. Before_completion hook exceptions propagate to the caller
#   3. dispatch_parallel with on_error: :skip returns nil for failing tasks
#   4. EventLoop drops unknown-target events with a warning (no crash)
# ---------------------------------------------------------------------------
RSpec.describe "Fault injection (Issue #213)" do
  # -------------------------------------------------------------------------
  # 1. Error translation at retry boundary (Issue #204 regression guard)
  # -------------------------------------------------------------------------
  describe "Error translation at retry boundary" do
    let(:translator) do
      Class.new do
        include Phronomy::Agent::Concerns::ErrorTranslation

        def test_translate(error)
          raise error
        rescue
          translate_and_reraise!($!)
        end

        public :test_translate
      end.new
    end

    it "translates RubyLLM::RateLimitError to Phronomy::RateLimitError" do
      expect {
        translator.test_translate(RubyLLM::RateLimitError.new("too many requests"))
      }.to raise_error(Phronomy::RateLimitError, "too many requests")
    end

    it "translated RateLimitError has the original as #cause" do
      original = RubyLLM::RateLimitError.new("limit hit")
      begin
        translator.test_translate(original)
      rescue Phronomy::RateLimitError => e
        expect(e.cause).to be(original)
      end
    end

    it "translates RubyLLM::UnauthorizedError to Phronomy::AuthenticationError" do
      expect {
        translator.test_translate(RubyLLM::UnauthorizedError.new("bad key"))
      }.to raise_error(Phronomy::AuthenticationError, "bad key")
    end

    it "translates RubyLLM::ContextLengthExceededError to Phronomy::ContextLengthError" do
      expect {
        translator.test_translate(RubyLLM::ContextLengthExceededError.new("too long"))
      }.to raise_error(Phronomy::ContextLengthError, "too long")
    end

    it "translates other RubyLLM::Error subclasses to Phronomy::TransportError" do
      expect {
        translator.test_translate(RubyLLM::Error.new("generic error"))
      }.to raise_error(Phronomy::TransportError, "generic error")
    end

    it "re-raises non-RubyLLM errors unchanged" do
      original = ArgumentError.new("bad argument")
      expect {
        translator.test_translate(original)
      }.to raise_error(original)
    end
  end

  # -------------------------------------------------------------------------
  # 2. before_llm_input hook exceptions propagate to the caller
  # -------------------------------------------------------------------------
  describe "before_llm_input hook fault injection" do
    let(:exploding_hook) { ->(_ctx) { raise "hook exploded" } }

    it "propagates an exception raised by a before_llm_input hook" do
      agent_class = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-105", version: 1
        model "test-model"
      end

      agent = agent_class.new
      agent.before_llm_input = exploding_hook

      expect {
        agent.send(:run_before_llm_input_hooks, call_sequence: 1, config: {})
      }.to raise_error(RuntimeError, "hook exploded")
    end

    it "propagates the exception unchanged (not translated to a Phronomy error)" do
      agent_class = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-106", version: 1
        model "test-model"
      end

      agent = agent_class.new
      agent.before_llm_input = ->(_ctx) { raise ArgumentError, "bad param" }

      expect {
        agent.send(:run_before_llm_input_hooks, call_sequence: 1, config: {})
      }.to raise_error(ArgumentError, "bad param")
    end
  end

  # -------------------------------------------------------------------------
  # 3. dispatch_parallel on_error: :skip — failing task returns nil
  # -------------------------------------------------------------------------
  describe "dispatch_parallel on_error: :skip fault isolation" do
    subject(:orchestrator) { Class.new(Phronomy::MultiAgent::Orchestrator).new }

    let(:good_agent) do
      Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-107", version: 1
        define_method(:invoke) { |input, **| {output: "ok:#{input}", messages: []} }
        define_method(:invoke_async) do |input, **_kw|
          Phronomy::Task.spawn(name: "stub-async") { invoke(input) }
        end
      end
    end

    let(:bad_agent) do
      Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-108", version: 1
        define_method(:invoke) { |*| raise "simulated failure" }
        define_method(:invoke_async) do |input, **_kw|
          Phronomy::Task.spawn(name: "stub-async") { invoke(input) }
        end
      end
    end

    it "returns nil for the failing task" do
      results = orchestrator.dispatch_parallel(
        {agent: good_agent, input: "a"},
        {agent: bad_agent, input: "b"},
        {agent: good_agent, input: "c"},
        on_error: :skip
      )

      expect(results[1]).to be_nil
    end

    it "does not affect the results of successful tasks" do
      results = orchestrator.dispatch_parallel(
        {agent: good_agent, input: "a"},
        {agent: bad_agent, input: "b"},
        {agent: good_agent, input: "c"},
        on_error: :skip
      )

      expect(results[0][:output]).to eq("ok:a")
      expect(results[2][:output]).to eq("ok:c")
    end

    it "all tasks still run (no fail-fast)" do
      ran = []
      mutex = Mutex.new

      tracking_good = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-109", version: 1
        define_method(:invoke) do |input, thread_id: nil, config: {}, invocation_context: nil, on_event: nil|
          mutex.synchronize { ran << input }
          {output: "ok", messages: []}
        end
        define_method(:invoke_async) do |input, thread_id: nil, config: {}, invocation_context: nil, on_tool_approval_required: nil, on_event: nil|
          Phronomy::Task.spawn(name: "stub-async") do
            invoke(
              input,
              thread_id: thread_id,
              config: config,
              invocation_context: invocation_context,
              on_event: on_event
            )
          end
        end
      end

      orchestrator.dispatch_parallel(
        {agent: tracking_good, input: "first"},
        {agent: bad_agent, input: "second"},
        {agent: tracking_good, input: "third"},
        on_error: :skip
      )

      expect(ran.sort).to eq(%w[first third])
    end
  end

  # -------------------------------------------------------------------------
  # 4. EventLoop: unknown target_id events are dropped with a warning, not raised
  # -------------------------------------------------------------------------
  describe "EventLoop unknown target_id fault tolerance" do
    before do
    end

    it "does not raise when posting an event with an unknown target_id" do
      loop = Phronomy::Runtime.instance.event_loop
      event = Phronomy::Event.new(
        type: :tool_result,
        target_id: "nonexistent-#{rand(1_000_000)}",
        payload: {}
      )

      expect {
        loop.post(event)
        sleep 0.05
      }.not_to raise_error
    end

    it "emits a warning to stderr for events with an unknown target_id" do
      loop = Phronomy::Runtime.instance.event_loop
      target = "unknown-target-#{rand(1_000_000)}"
      event = Phronomy::Event.new(type: :tool_result, target_id: target, payload: {})

      expect {
        loop.post(event)
        sleep 0.05
      }.to output(/Dropped event :tool_result/).to_stderr
    end

    it "continues processing subsequent events after an unknown target_id event" do
      loop = Phronomy::Runtime.instance.event_loop

      loop.post(Phronomy::Event.new(
        type: :tool_result,
        target_id: "ghost-target",
        payload: {}
      ))

      sleep 0.05
      task = loop.instance_variable_get(:@task)
      expect(task).to be_alive
    end
  end
end
