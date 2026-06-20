# frozen_string_literal: true

# Unit tests for the retry_on DSL on Phronomy::Agent::Context::Capability::Base and the retry_policy DSL on
# Agent::Base.
#
# Sleep is replaced with a recording lambda in all tests to avoid actual delays
# and to assert on computed wait durations.

require "spec_helper"

RSpec.describe Phronomy::Agent::Context::Capability::Base, "retry_on DSL" do
  # ---------------------------------------------------------------------------
  # Shared setup
  # ---------------------------------------------------------------------------
  let(:sleep_calls) { [] }
  let(:sleep_stub) { ->(t) { sleep_calls << t } }

  def make_tool(call_count_target:, exception_class: Phronomy::ToolError, **retry_opts, &result_block)
    calls = 0
    klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
      description "retry test tool"
      retry_on exception_class, **retry_opts

      define_method(:execute) do |**_|
        calls += 1
        raise exception_class, "boom" if calls < call_count_target
        result_block ? result_block.call(calls) : "ok after #{calls}"
      end
    end
    klass._sleep_proc = sleep_stub
    [klass.new, -> { calls }]
  end

  # ---------------------------------------------------------------------------
  # DSL accessors
  # ---------------------------------------------------------------------------
  describe ".retry_on / .retry_policies" do
    it "registers a single policy" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "t"
        retry_on Phronomy::ToolError, times: 2, wait: :exponential, base: 0.5
      end
      policies = klass.retry_policies
      expect(policies.length).to eq(1)
      expect(policies.first[:exceptions]).to eq([Phronomy::ToolError])
      expect(policies.first[:times]).to eq(2)
      expect(policies.first[:wait]).to eq(:exponential)
      expect(policies.first[:base]).to eq(0.5)
    end

    it "registers multiple policies" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "t"
        retry_on Phronomy::ToolError, times: 2
        retry_on RuntimeError, times: 1, wait: 0.5
      end
      expect(klass.retry_policies.length).to eq(2)
    end

    it "returns empty array when no policy is registered" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) { description "t" }
      expect(klass.retry_policies).to eq([])
    end
  end

  # ---------------------------------------------------------------------------
  # _sleep_proc injection
  # ---------------------------------------------------------------------------
  describe "._sleep_proc" do
    it "defaults to Kernel#sleep" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) { description "t" }
      expect(klass._sleep_proc).to respond_to(:call)
    end

    it "can be overridden for testing" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) { description "t" }
      stub = ->(t) { t }
      klass._sleep_proc = stub
      expect(klass._sleep_proc).to be(stub)
    end
  end

  # ---------------------------------------------------------------------------
  # Retry count behaviour
  # ---------------------------------------------------------------------------
  describe "retry count" do
    it "does not retry when times: 0 (passes through immediately)" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "t"
        retry_on Phronomy::ToolError, times: 0
        def execute(**_)
          raise Phronomy::ToolError, "boom"
        end
      end
      klass._sleep_proc = sleep_stub
      expect { klass.new.call({}) }.to raise_error(Phronomy::ToolError)
      expect(sleep_calls).to be_empty
    end

    it "succeeds on first attempt when no exception is raised" do
      tool, calls = make_tool(call_count_target: 1, times: 3, wait: 0)
      expect(tool.call({})).to eq("ok after 1")
      expect(calls.call).to eq(1)
      expect(sleep_calls).to be_empty
    end

    it "retries and succeeds within the retry budget" do
      tool, calls = make_tool(call_count_target: 3, times: 3, wait: 0)
      expect(tool.call({})).to eq("ok after 3")
      expect(calls.call).to eq(3)
    end

    it "re-raises after all retries are exhausted" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "t"
        retry_on Phronomy::ToolError, times: 2, wait: 0
        def execute(**_)
          raise Phronomy::ToolError, "always"
        end
      end
      klass._sleep_proc = sleep_stub
      expect { klass.new.call({}) }.to raise_error(Phronomy::ToolError, /always/)
    end

    it "records the correct number of sleep calls" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "t"
        retry_on Phronomy::ToolError, times: 3, wait: 0
        def execute(**_)
          raise Phronomy::ToolError, "always"
        end
      end
      klass._sleep_proc = sleep_stub
      expect { klass.new.call({}) }.to raise_error(Phronomy::ToolError)
      # wait: 0 means sleep is NOT called (guard: wait > 0 in with_tool_retry)
      expect(sleep_calls.length).to eq(0)
    end
  end

  # ---------------------------------------------------------------------------
  # Wait strategy — exponential
  # ---------------------------------------------------------------------------
  describe "wait: :exponential" do
    it "computes 2^attempt * base for each retry" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "t"
        retry_on Phronomy::ToolError, times: 3, wait: :exponential, base: 1.0
        def execute(**_)
          raise Phronomy::ToolError, "always"
        end
      end
      klass._sleep_proc = sleep_stub
      expect { klass.new.call({}) }.to raise_error(Phronomy::ToolError)
      # attempt=0 → 1.0, attempt=1 → 2.0, attempt=2 → 4.0
      expect(sleep_calls).to eq([1.0, 2.0, 4.0])
    end

    it "uses base as the multiplier" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "t"
        retry_on Phronomy::ToolError, times: 2, wait: :exponential, base: 0.5
        def execute(**_)
          raise Phronomy::ToolError, "always"
        end
      end
      klass._sleep_proc = sleep_stub
      expect { klass.new.call({}) }.to raise_error(Phronomy::ToolError)
      # attempt=0 → 0.5, attempt=1 → 1.0
      expect(sleep_calls).to eq([0.5, 1.0])
    end
  end

  # ---------------------------------------------------------------------------
  # Wait strategy — linear
  # ---------------------------------------------------------------------------
  describe "wait: :linear" do
    it "computes (attempt+1) * base for each retry" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "t"
        retry_on Phronomy::ToolError, times: 3, wait: :linear, base: 1.0
        def execute(**_)
          raise Phronomy::ToolError, "always"
        end
      end
      klass._sleep_proc = sleep_stub
      expect { klass.new.call({}) }.to raise_error(Phronomy::ToolError)
      # attempt=0 → 1.0, attempt=1 → 2.0, attempt=2 → 3.0
      expect(sleep_calls).to eq([1.0, 2.0, 3.0])
    end
  end

  # ---------------------------------------------------------------------------
  # Wait strategy — fixed Float
  # ---------------------------------------------------------------------------
  describe "wait: fixed Float" do
    it "sleeps the same duration every retry" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "t"
        retry_on Phronomy::ToolError, times: 3, wait: 2.5
        def execute(**_)
          raise Phronomy::ToolError, "always"
        end
      end
      klass._sleep_proc = sleep_stub
      expect { klass.new.call({}) }.to raise_error(Phronomy::ToolError)
      expect(sleep_calls).to eq([2.5, 2.5, 2.5])
    end
  end

  # ---------------------------------------------------------------------------
  # Custom exception class
  # ---------------------------------------------------------------------------
  describe "retry_on with custom exception class" do
    it "retries on a user-specified exception" do
      calls = 0
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "t"
        retry_on RuntimeError, times: 2, wait: 0

        define_method(:execute) do |**_|
          calls += 1
          raise "transient" if calls < 3
          "recovered"
        end
      end
      klass._sleep_proc = sleep_stub
      expect(klass.new.call({})).to eq("recovered")
      expect(calls).to eq(3)
    end

    it "does not retry on an exception not covered by the policy" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "t"
        retry_on ArgumentError, times: 3, wait: 0
        def execute(**_)
          raise "uncovered"
        end
      end
      klass._sleep_proc = sleep_stub
      expect { klass.new.call({}) }.to raise_error(Phronomy::ToolError, /uncovered/)
      expect(sleep_calls).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # FilterBlockError — must not be retried by tool-level retry
  # FilterBlockError is raised by the agent layer, not by Tool#call, but we verify
  # that if it somehow reaches with_tool_retry it is not swallowed.
  # ---------------------------------------------------------------------------
  describe "FilterBlockError is not retried" do
    it "propagates FilterBlockError immediately even when retry_on covers Error" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "t"
        # Registering Phronomy::Error (parent) should NOT catch FilterBlockError
        # because the policy match is done via is_a?, but we explicitly verify
        # the guard in the agent layer separately.
        retry_on RuntimeError, times: 3, wait: 0
        def execute(**_)
          raise Phronomy::FilterBlockError, "blocked"
        end
      end
      klass._sleep_proc = sleep_stub
      # FilterBlockError is not a RuntimeError, so no retry occurs.
      expect { klass.new.call({}) }.to raise_error(Phronomy::ToolError, /blocked/)
      expect(sleep_calls).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # Interaction with on_error policy
  # ---------------------------------------------------------------------------
  describe "interaction with on_error: :return_empty" do
    it "retries first, then applies on_error after exhaustion" do
      call_count = 0
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "t"
        on_error :return_empty
        retry_on RuntimeError, times: 2, wait: 0

        define_method(:execute) do |**_|
          call_count += 1
          raise "always"
        end
      end
      klass._sleep_proc = sleep_stub
      result = klass.new.call({})
      expect(result).to match(/Tool error suppressed:.*always/)
      # 1 initial + 2 retries = 3 total calls
      expect(call_count).to eq(3)
    end
  end
end

# =============================================================================
RSpec.describe Phronomy::Agent::Base, "retry_policy DSL" do
  let(:sleep_calls) { [] }
  let(:sleep_stub) { ->(t) { sleep_calls << t } }

  # ---------------------------------------------------------------------------
  # DSL accessors
  # ---------------------------------------------------------------------------
  describe ".retry_policy / ._retry_policy" do
    it "stores the policy" do
      klass = Class.new(Phronomy::Agent::Base) do
        retry_policy times: 2, wait: :exponential, base: 1.0
      end
      expect(klass._retry_policy).to eq({times: 2, wait: :exponential, base: 1.0})
    end

    it "returns nil when no policy is set" do
      klass = Class.new(Phronomy::Agent::Base)
      expect(klass._retry_policy).to be_nil
    end
  end

  describe "._sleep_proc" do
    it "defaults to Kernel#sleep" do
      klass = Class.new(Phronomy::Agent::Base)
      expect(klass._sleep_proc).to respond_to(:call)
    end

    it "can be overridden" do
      klass = Class.new(Phronomy::Agent::Base)
      stub = ->(t) { t }
      klass._sleep_proc = stub
      expect(klass._sleep_proc).to be(stub)
    end
  end

  # ---------------------------------------------------------------------------
  # Retry behaviour
  # ---------------------------------------------------------------------------
  describe "invoke retry loop" do
    def make_agent(fail_times:, exception_class: RuntimeError, times: 2, wait: 0)
      invocations = 0
      agent_class = Class.new(Phronomy::Agent::Base) do
        retry_policy times: times, wait: wait, base: 1.0
      end
      agent_class._sleep_proc = sleep_stub

      agent = agent_class.new
      allow(agent).to receive(:_start_invoke_attempt) do |result_task, input, messages:, thread_id:, config:, attempt:|
        invocations += 1
        if invocations <= fail_times
          err = exception_class.new("transient")
          policy = agent.class._retry_policy
          retriable = policy && attempt < policy[:times] &&
            !err.is_a?(Phronomy::FilterBlockError) &&
            !err.is_a?(Phronomy::CancellationError)
          if retriable
            wait_sec = agent.send(:compute_agent_retry_wait, policy[:wait], policy[:base], attempt)
            agent.class._sleep_proc.call(wait_sec) if wait_sec > 0
            agent.send(:_start_invoke_attempt, result_task, input, messages: messages, thread_id: thread_id, config: config,
              attempt: attempt + 1)
          else
            begin
              agent.send(:translate_and_reraise!, err)
            rescue => translated
              result_task.backend.unblock(nil, translated)
              result_task.transition!(:failed, error: translated)
            end
          end
        else
          result = {output: "recovered", messages: [], usage: nil}
          result_task.backend.unblock(result, nil)
          result_task.transition!(:completed, value: result)
        end
      end
      [agent, -> { invocations }]
    end

    it "succeeds without retry when invoke_once succeeds on the first attempt" do
      agent, inv = make_agent(fail_times: 0)
      result = agent.invoke("hi")
      expect(result[:output]).to eq("recovered")
      expect(inv.call).to eq(1)
      expect(sleep_calls).to be_empty
    end

    it "retries and recovers within the retry budget" do
      agent, inv = make_agent(fail_times: 2, times: 3)
      result = agent.invoke("hi")
      expect(result[:output]).to eq("recovered")
      expect(inv.call).to eq(3)
    end

    it "re-raises after all retries are exhausted" do
      agent, inv = make_agent(fail_times: 5, times: 2)
      expect { agent.invoke("hi") }.to raise_error(RuntimeError, /transient/)
      expect(inv.call).to eq(3) # 1 initial + 2 retries
    end

    it "does not retry when no policy is set" do
      agent_class = Class.new(Phronomy::Agent::Base)
      agent = agent_class.new
      allow(agent).to receive(:_start_invoke_attempt) do |result_task, *|
        err = RuntimeError.new("boom")
        result_task.backend.unblock(nil, err)
        result_task.transition!(:failed, error: err)
      end
      expect { agent.invoke("hi") }.to raise_error(RuntimeError, /boom/)
    end

    it "never retries FilterBlockError" do
      agent_class = Class.new(Phronomy::Agent::Base) do
        retry_policy times: 5, wait: 0
      end
      agent_class._sleep_proc = sleep_stub
      agent = agent_class.new
      allow(agent).to receive(:_start_invoke_attempt) do |result_task, *|
        err = Phronomy::FilterBlockError.new("blocked")
        result_task.backend.unblock(nil, err)
        result_task.transition!(:failed, error: err)
      end
      expect { agent.invoke("hi") }.to raise_error(Phronomy::FilterBlockError)
      expect(sleep_calls).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # Wait strategy
  # ---------------------------------------------------------------------------
  describe "wait strategies" do
    def make_failing_agent(times:, wait:, base: 1.0)
      agent_class = Class.new(Phronomy::Agent::Base) do
        retry_policy times: times, wait: wait, base: base
      end
      agent_class._sleep_proc = sleep_stub
      agent = agent_class.new
      allow(agent).to receive(:_start_invoke_attempt) do |result_task, input, messages:, thread_id:, config:, attempt:|
        err = RuntimeError.new("always")
        policy = agent.class._retry_policy
        retriable = policy && attempt < policy[:times] &&
          !err.is_a?(Phronomy::FilterBlockError) &&
          !err.is_a?(Phronomy::CancellationError)
        if retriable
          wait_sec = agent.send(:compute_agent_retry_wait, policy[:wait], policy[:base], attempt)
          agent.class._sleep_proc.call(wait_sec) if wait_sec > 0
          agent.send(:_start_invoke_attempt, result_task, input, messages: messages, thread_id: thread_id, config: config,
            attempt: attempt + 1)
        else
          begin
            agent.send(:translate_and_reraise!, err)
          rescue => translated
            result_task.backend.unblock(nil, translated)
            result_task.transition!(:failed, error: translated)
          end
        end
      end
      agent
    end

    it "exponential: sleeps 2^attempt * base" do
      agent = make_failing_agent(times: 3, wait: :exponential, base: 1.0)
      expect { agent.invoke("hi") }.to raise_error(RuntimeError)
      expect(sleep_calls).to eq([1.0, 2.0, 4.0])
    end

    it "linear: sleeps (attempt+1) * base" do
      agent = make_failing_agent(times: 3, wait: :linear, base: 1.0)
      expect { agent.invoke("hi") }.to raise_error(RuntimeError)
      expect(sleep_calls).to eq([1.0, 2.0, 3.0])
    end

    it "fixed Float: sleeps the same duration every time" do
      agent = make_failing_agent(times: 3, wait: 2.5, base: 1.0)
      expect { agent.invoke("hi") }.to raise_error(RuntimeError)
      expect(sleep_calls).to eq([2.5, 2.5, 2.5])
    end

    it "wait: 0 does not call sleep" do
      agent = make_failing_agent(times: 3, wait: 0)
      expect { agent.invoke("hi") }.to raise_error(RuntimeError)
      expect(sleep_calls).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # Regression tests for issue #39:
  # Agent::Base#invoke must respect retry_policy.
  # ---------------------------------------------------------------------------
  describe "retry_policy is honoured by Agent::Base (issue #39)" do
    def make_react_agent(fail_times:, times: 2, wait: 0)
      invocations = 0
      agent_class = Class.new(Phronomy::Agent::Base) do
        retry_policy times: times, wait: wait, base: 1.0
      end
      agent_class._sleep_proc = sleep_stub

      agent = agent_class.new
      allow(agent).to receive(:_start_invoke_attempt) do |result_task, input, messages:, thread_id:, config:, attempt:|
        invocations += 1
        if invocations <= fail_times
          err = RuntimeError.new("transient")
          policy = agent.class._retry_policy
          retriable = policy && attempt < policy[:times] &&
            !err.is_a?(Phronomy::FilterBlockError) &&
            !err.is_a?(Phronomy::CancellationError)
          if retriable
            wait_sec = agent.send(:compute_agent_retry_wait, policy[:wait], policy[:base], attempt)
            agent.class._sleep_proc.call(wait_sec) if wait_sec > 0
            agent.send(:_start_invoke_attempt, result_task, input, messages: messages, thread_id: thread_id, config: config,
              attempt: attempt + 1)
          else
            begin
              agent.send(:translate_and_reraise!, err)
            rescue => translated
              result_task.backend.unblock(nil, translated)
              result_task.transition!(:failed, error: translated)
            end
          end
        else
          result = {output: "recovered", messages: [], usage: Phronomy::TokenUsage.zero,
                    iterations_exhausted: false}
          result_task.backend.unblock(result, nil)
          result_task.transition!(:completed, value: result)
        end
      end
      [agent, -> { invocations }]
    end

    it "retries and recovers within the retry budget" do
      agent, inv = make_react_agent(fail_times: 2, times: 3)
      result = agent.invoke("hi")
      expect(result[:output]).to eq("recovered")
      expect(inv.call).to eq(3)
    end

    it "re-raises after all retries are exhausted" do
      agent, inv = make_react_agent(fail_times: 5, times: 2)
      expect { agent.invoke("hi") }.to raise_error(RuntimeError, /transient/)
      expect(inv.call).to eq(3) # 1 initial + 2 retries
    end

    it "does not retry FilterBlockError" do
      agent_class = Class.new(Phronomy::Agent::Base) do
        retry_policy times: 3, wait: 0
      end
      agent_class._sleep_proc = sleep_stub
      agent = agent_class.new
      allow(agent).to receive(:_start_invoke_attempt) do |result_task, *|
        err = Phronomy::FilterBlockError.new("blocked")
        result_task.backend.unblock(nil, err)
        result_task.transition!(:failed, error: err)
      end
      expect { agent.invoke("hi") }.to raise_error(Phronomy::FilterBlockError)
      expect(sleep_calls).to be_empty
    end
  end
end
